#!/usr/bin/env bash
# Exposes the local Supergateway port to the internet for remote MCP clients (e.g. Poke).
# Writes the public MCP URL to Application Support and logs.

set -euo pipefail

# shellcheck disable=SC1091
source "${ULTRAGATEWAY_CONFIG:-${HOME}/Library/Application Support/ultragateway/config.env}" 2>/dev/null || true

: "${SUPERGATEWAY_PORT:=8000}"
: "${TUNNEL_PROVIDER:=tailscale}"
: "${TUNNEL_MCP_PATH:=/sse}"
: "${TUNNEL_WAIT_SECONDS:=120}"

SUPPORT_DIR="${HOME}/Library/Application Support/ultragateway"
LOG_DIR="${HOME}/Library/Logs/ultragateway"
PUBLIC_MCP_URL_FILE="${SUPPORT_DIR}/public-mcp-url.txt"
PUBLIC_BASE_URL_FILE="${SUPPORT_DIR}/public-base-url.txt"
TUNNEL_LOG="${LOG_DIR}/tunnel.log"

export PATH="${PATH:-/usr/bin:/bin}"

mkdir -p "$SUPPORT_DIR" "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$TUNNEL_LOG"
}

write_public_urls() {
  local base_url="$1"
  base_url="${base_url%%$'\n'*}"
  base_url="${base_url//$'\r'/}"
  base_url="${base_url%/}"
  local mcp_url="${base_url}${TUNNEL_MCP_PATH}"

  printf '%s\n' "$mcp_url" > "$PUBLIC_MCP_URL_FILE"
  printf '%s\n' "$base_url" > "$PUBLIC_BASE_URL_FILE"
  log "Public base URL:  ${base_url}"
  log "Public MCP URL:   ${mcp_url}  (paste this into Poke)"
}

port_open() {
  nc -z 127.0.0.1 "${SUPERGATEWAY_PORT}" 2>/dev/null
}

wait_for_gateway() {
  local waited=0
  log "Waiting for Supergateway on 127.0.0.1:${SUPERGATEWAY_PORT}..."
  while (( waited < TUNNEL_WAIT_SECONDS )); do
    if port_open; then
      log "Supergateway port is open"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log "ERROR: Supergateway did not become ready within ${TUNNEL_WAIT_SECONDS}s"
  exit 1
}

require_command() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: '$cmd' not found. ${hint}"
    exit 1
  fi
}

tailscale_public_base_url() {
  local url=""

  if command -v python3 >/dev/null 2>&1; then
    url="$(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    name = (data.get("Self") or {}).get("DNSName") or ""
    name = name.rstrip(".")
    if name:
        print(f"https://{name}")
except Exception:
    pass
' || true)"
    url="${url%%$'\n'*}"
    if [[ -n "$url" ]]; then
      printf '%s\n' "$url"
      return 0
    fi
  fi

  local status_out
  status_out="$(tailscale funnel status 2>/dev/null || true)"
  if [[ -n "$status_out" ]]; then
    url="$(printf '%s\n' "$status_out" | grep -Eo 'https://[^[:space:]]+' | head -1 || true)"
    if [[ -n "$url" ]]; then
      printf '%s\n' "$url"
      return 0
    fi
  fi
  return 1
}

run_tailscale() {
  require_command tailscale "Install Tailscale: https://tailscale.com/download"

  log "Starting Tailscale Funnel for port ${SUPERGATEWAY_PORT} (--bg)"
  if tailscale funnel --bg --yes "${SUPERGATEWAY_PORT}" 2>&1 | tee -a "$TUNNEL_LOG"; then
    log "Tailscale Funnel configured"
  else
    log "ERROR: tailscale funnel failed (macOS App Store build may need open-source Tailscale for --bg)"
    exit 1
  fi

  sleep 2
  local base_url
  base_url="$(tailscale_public_base_url || true)"
  base_url="${base_url%%$'\n'*}"
  if [[ -z "$base_url" ]]; then
    log "ERROR: Could not determine Tailscale public URL. Run: tailscale funnel status"
    exit 1
  fi
  write_public_urls "$base_url"

  log "Tailscale Funnel running in background. Monitoring gateway health..."
  while true; do
    if ! port_open; then
      log "WARNING: local gateway port closed — Tailscale Funnel remains active"
    fi
    sleep 60
  done
}

run_cloudflared() {
  require_command cloudflared "Install: brew install cloudflared"

  log "Starting Cloudflare quick tunnel to http://127.0.0.1:${SUPERGATEWAY_PORT}"
  cloudflared tunnel --url "http://127.0.0.1:${SUPERGATEWAY_PORT}" --no-autoupdate 2>&1 | tee -a "$TUNNEL_LOG" | while IFS= read -r line; do
    if [[ "$line" =~ (https://[a-zA-Z0-9.-]+\.trycloudflare\.com) ]]; then
      write_public_urls "${BASH_REMATCH[1]}"
    fi
  done
}

run_ngrok() {
  require_command ngrok "Install: brew install ngrok, then ngrok config add-authtoken <token>"

  log "Starting ngrok http ${SUPERGATEWAY_PORT}"
  ngrok http "${SUPERGATEWAY_PORT}" --log=stdout 2>&1 | tee -a "$TUNNEL_LOG" &
  local ngrok_pid=$!

  local base_url=""
  for _ in $(seq 1 45); do
    if command -v python3 >/dev/null 2>&1; then
      base_url="$(curl -sf http://127.0.0.1:4040/api/tunnels 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for t in data.get("tunnels", []):
        url = t.get("public_url", "")
        if url.startswith("https://"):
            print(url.rstrip("/"))
            break
except Exception:
    pass
' || true)"
    fi
    if [[ -n "$base_url" ]]; then
      write_public_urls "$base_url"
      break
    fi
    sleep 1
  done

  if [[ -z "$base_url" ]]; then
    log "ERROR: ngrok started but public URL was not discovered (check ngrok auth token)"
    kill "$ngrok_pid" 2>/dev/null || true
    exit 1
  fi

  wait "$ngrok_pid"
}

TUNNEL_PROVIDER_LC="$(printf '%s' "$TUNNEL_PROVIDER" | tr '[:upper:]' '[:lower:]')"

case "$TUNNEL_PROVIDER_LC" in
  none|off|false|disabled)
    log "Tunnel disabled (TUNNEL_PROVIDER=${TUNNEL_PROVIDER:-none})"
    rm -f "$PUBLIC_MCP_URL_FILE" "$PUBLIC_BASE_URL_FILE"
    exit 0
  ;;
  tailscale)
    wait_for_gateway
    run_tailscale
  ;;
  cloudflare|cloudflared)
    wait_for_gateway
    run_cloudflared
  ;;
  ngrok)
    wait_for_gateway
    run_ngrok
  ;;
  *)
    log "ERROR: Unknown TUNNEL_PROVIDER='${TUNNEL_PROVIDER}'. Use: tailscale | cloudflare | ngrok | none"
    exit 1
  ;;
esac
