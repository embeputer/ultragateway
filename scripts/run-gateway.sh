#!/usr/bin/env bash
# Starts Supergateway bridged to the CUA MCP server over STDIO.
# Intended to be run by launchd (LaunchAgent) or manually for debugging.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="${HOME}/Library/Application Support/ultragateway"

# shellcheck disable=SC1091
source "${ULTRAGATEWAY_CONFIG:-${SUPPORT_DIR}/config.env}" 2>/dev/null || true

: "${CUA_DRIVER_BIN:=${HOME}/.local/bin/cua-driver}"
: "${SUPERGATEWAY_PORT:=8000}"
: "${SUPERGATEWAY_LOG_LEVEL:=info}"
: "${SUPERGATEWAY_OUTPUT_TRANSPORT:=sse}"
: "${SUPERGATEWAY_VERSION:=3.4.3}"

export PATH="${PATH:-/usr/bin:/bin}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

require_command() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: '$cmd' not found. ${hint}"
    exit 1
  fi
}

require_command node "Install Node.js (https://nodejs.org) or: brew install node"
require_command npm "Ensure npm is on PATH (e.g. npm config set prefix ~/.npm-global)"

if [[ ! -x "$CUA_DRIVER_BIN" ]]; then
  log "ERROR: cua-driver not found or not executable at: $CUA_DRIVER_BIN"
  log "Install from https://github.com/trycua/cua-driver or set CUA_DRIVER_BIN in config.env"
  exit 1
fi

SUPERGATEWAY_DIR="${SUPPORT_DIR}/supergateway-npm"
SUPERGATEWAY_BIN="${SUPERGATEWAY_DIR}/node_modules/.bin/supergateway"
PATCH_SCRIPT="${SCRIPT_DIR}/patch-supergateway-sse.js"

supergateway_install_broken() {
  local node_modules="${SUPERGATEWAY_DIR}/node_modules"
  [[ ! -x "$SUPERGATEWAY_BIN" ]] && return 0
  # body-parser depends on iconv-lite; a partial npm install breaks all POST routes
  # (Poke validates MCP servers with POST, so a missing iconv-lite shows as "invalid server url")
  [[ ! -f "${node_modules}/iconv-lite/lib/index.js" ]] && return 0
  [[ ! -f "${node_modules}/iconv-lite/encodings/index.js" ]] && return 0
  return 1
}

install_supergateway() {
  log "Installing supergateway@${SUPERGATEWAY_VERSION} to ${SUPERGATEWAY_DIR}"
  rm -rf "$SUPERGATEWAY_DIR"
  mkdir -p "$SUPERGATEWAY_DIR"
  npm install --prefix "$SUPERGATEWAY_DIR" --no-save --no-package-lock "supergateway@${SUPERGATEWAY_VERSION}"
}

ensure_supergateway() {
  if supergateway_install_broken; then
    if [[ -d "$SUPERGATEWAY_DIR" ]]; then
      log "Supergateway install is incomplete (missing npm deps); reinstalling..."
    fi
    install_supergateway
  fi

  if [[ ! -f "$PATCH_SCRIPT" ]]; then
    log "ERROR: patch script not found at ${PATCH_SCRIPT}"
    log "Re-run install.sh from the ultragateway repo to update scripts."
    exit 1
  fi

  if [[ "$SUPERGATEWAY_OUTPUT_TRANSPORT" == "sse" ]]; then
    local sse_file="${SUPERGATEWAY_DIR}/node_modules/supergateway/dist/gateways/stdioToSse.js"
    if [[ -f "$sse_file" ]]; then
      node "$PATCH_SCRIPT" "$sse_file"
    fi
  fi
}

ensure_supergateway

NATIVE_MCP_DIR="${SUPPORT_DIR}/native-mcp"
NATIVE_MCP_SERVER="${NATIVE_MCP_DIR}/composite-server.mjs"

ensure_native_mcp() {
  if [[ ! -f "$NATIVE_MCP_SERVER" ]]; then
    log "ERROR: native MCP server not found at ${NATIVE_MCP_SERVER}"
    log "Re-run install.sh from the ultragateway repo."
    exit 1
  fi
  if [[ ! -f "${NATIVE_MCP_DIR}/node_modules/@modelcontextprotocol/sdk/package.json" ]]; then
    log "Installing native-mcp dependencies to ${NATIVE_MCP_DIR}"
    npm install --prefix "$NATIVE_MCP_DIR" --no-save --no-package-lock
  fi
}

ensure_native_mcp

export ULTRAGATEWAY_SUPPORT_DIR="$SUPPORT_DIR"
export CUA_DRIVER_BIN
export NATIVE_SHELL_ENABLED="${NATIVE_SHELL_ENABLED:-1}"
export NATIVE_SHELL_TIMEOUT="${NATIVE_SHELL_TIMEOUT:-30}"
export NATIVE_SHELL_TIMEOUT_MAX="${NATIVE_SHELL_TIMEOUT_MAX:-300}"
export NATIVE_NOTIFY_ENABLED="${NATIVE_NOTIFY_ENABLED:-1}"

log "Starting Supergateway on port ${SUPERGATEWAY_PORT} (${SUPERGATEWAY_OUTPUT_TRANSPORT})"
log "Composite MCP: cua-driver + ultragateway native tools (run_zsh, notify)"

exec "$SUPERGATEWAY_BIN" \
  --stdio "node ${NATIVE_MCP_SERVER}" \
  --port "${SUPERGATEWAY_PORT}" \
  --outputTransport "${SUPERGATEWAY_OUTPUT_TRANSPORT}" \
  --logLevel "${SUPERGATEWAY_LOG_LEVEL}"
