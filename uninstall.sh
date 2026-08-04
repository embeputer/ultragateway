#!/usr/bin/env bash
# Uninstall ultragateway LaunchAgents, app, and optionally support files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ultragateway"
APP_BUNDLE="/Applications/${APP_NAME}.app"
SUPPORT_DIR="${HOME}/Library/Application Support/ultragateway"
LOG_DIR="${HOME}/Library/Logs/ultragateway"
GATEWAY_AGENT="${HOME}/Library/LaunchAgents/com.ultragateway.em.plist"
TUNNEL_AGENT="${HOME}/Library/LaunchAgents/com.ultragateway.em.tunnel.plist"
GATEWAY_LABEL="com.ultragateway.em"
TUNNEL_LABEL="com.ultragateway.em.tunnel"

LEGACY_GATEWAY_AGENT="${HOME}/Library/LaunchAgents/com.ultragateway.cua.plist"
LEGACY_TUNNEL_AGENT="${HOME}/Library/LaunchAgents/com.ultragateway.tunnel.plist"
LEGACY_MENUBAR_AGENT="${HOME}/Library/LaunchAgents/com.ultragateway.menubar.plist"
LEGACY_GATEWAY_LABEL="com.ultragateway.cua"
LEGACY_TUNNEL_LABEL="com.ultragateway.tunnel"
LEGACY_MENUBAR_LABEL="com.ultragateway.menubar"

LEGACY_APP_NAME="UltraGateway"
LEGACY_APP_BUNDLE="/Applications/${LEGACY_APP_NAME}.app"
LEGACY_SUPPORT_DIR="${HOME}/Library/Application Support/UltraGateway"
LEGACY_LOG_DIR="${HOME}/Library/Logs/UltraGateway"

PURGE="${1:-}"

info() { printf '==> %s\n' "$*"; }

remove_login_item() {
  local name="$1"
  osascript <<EOF 2>/dev/null || true
tell application "System Events"
  if exists login item "${name}" then
    delete login item "${name}"
  end if
end tell
EOF
}

info "Stopping LaunchAgents..."
launchctl bootout "gui/$(id -u)/${TUNNEL_LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${GATEWAY_LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${LEGACY_TUNNEL_LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${LEGACY_GATEWAY_LABEL}" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/${LEGACY_MENUBAR_LABEL}" 2>/dev/null || true

if command -v tailscale >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source "${SUPPORT_DIR}/config.env" 2>/dev/null || \
    source "${LEGACY_SUPPORT_DIR}/config.env" 2>/dev/null || true
  if [[ "${TUNNEL_PROVIDER:-tailscale}" == "tailscale" ]] && [[ -n "${SUPERGATEWAY_PORT:-8000}" ]]; then
    tailscale funnel "${SUPERGATEWAY_PORT:-8000}" off 2>/dev/null || true
  fi
fi

for agent in "$GATEWAY_AGENT" "$TUNNEL_AGENT" "$LEGACY_GATEWAY_AGENT" "$LEGACY_TUNNEL_AGENT" "$LEGACY_MENUBAR_AGENT"; do
  if [[ -f "$agent" ]]; then
    info "Removing ${agent}"
    rm -f "$agent"
  fi
done

for bundle in "$APP_BUNDLE" "$LEGACY_APP_BUNDLE"; do
  if [[ -d "$bundle" ]]; then
    info "Removing ${bundle}"
    rm -rf "$bundle"
  fi
done

info "Removing login items..."
remove_login_item "$APP_NAME"
remove_login_item "$LEGACY_APP_NAME"

if [[ "$PURGE" == "--purge" ]]; then
  info "Purging support files and logs..."
  rm -rf "$SUPPORT_DIR" "$LOG_DIR" "$LEGACY_SUPPORT_DIR" "$LEGACY_LOG_DIR"
else
  info "Keeping config and logs (run with --purge to remove):"
  info "  ${SUPPORT_DIR}"
  info "  ${LOG_DIR}"
  if [[ -d "$LEGACY_SUPPORT_DIR" || -d "$LEGACY_LOG_DIR" ]]; then
    info "Legacy paths (from UltraGateway rename) may still exist:"
    [[ -d "$LEGACY_SUPPORT_DIR" ]] && info "  ${LEGACY_SUPPORT_DIR}"
    [[ -d "$LEGACY_LOG_DIR" ]] && info "  ${LEGACY_LOG_DIR}"
    info "Run with --purge to remove legacy paths too."
  fi
fi

info "Uninstall complete."
