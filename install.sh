#!/usr/bin/env bash
# Install ultragateway: background LaunchAgents + LSUIElement menu bar app in /Applications.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

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

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

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

migrate_config_env() {
  local config="${SUPPORT_DIR}/config.env"
  local example="${REPO_ROOT}/config.env.example"
  [[ -f "$config" && -f "$example" ]] || return 0

  if grep -q 'UltraGateway' "$config" 2>/dev/null; then
    info "Updating config.env header (UltraGateway → ultragateway)..."
    if sed --version >/dev/null 2>&1; then
      sed -i 's|Application Support/UltraGateway|Application Support/ultragateway|g' "$config"
    else
      sed -i '' 's|Application Support/UltraGateway|Application Support/ultragateway|g' "$config"
    fi
  fi

  local added=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    local key="${line%%=*}"
    key="${key%%[[:space:]]*}"
    [[ -n "$key" ]] || continue
    if ! grep -q "^${key}=" "$config" 2>/dev/null; then
      printf '%s\n' "$line" >> "$config"
      added=1
    fi
  done < "$example"

  if (( added )); then
    info "Added missing settings to config.env from config.env.example"
  fi
}

same_path() {
  local a="$1" b="$2"
  [[ -e "$a" && -e "$b" ]] || return 1
  local ca cb
  ca="$(cd "$(dirname "$a")" && pwd -P)/$(basename "$a")"
  cb="$(cd "$(dirname "$b")" && pwd -P)/$(basename "$b")"
  [[ "$ca" == "$cb" ]]
}

migrate_launch_agents() {
  info "Migrating LaunchAgents (legacy labels → com.ultragateway.em)..."
  launchctl bootout "gui/$(id -u)/${LEGACY_GATEWAY_LABEL}" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/${LEGACY_TUNNEL_LABEL}" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/${LEGACY_MENUBAR_LABEL}" 2>/dev/null || true
  rm -f "$LEGACY_GATEWAY_AGENT" "$LEGACY_TUNNEL_AGENT" "$LEGACY_MENUBAR_AGENT"
}

migrate_from_legacy() {
  if [[ -d "$LEGACY_APP_BUNDLE" && "$LEGACY_APP_BUNDLE" != "$APP_BUNDLE" ]] && ! same_path "$LEGACY_APP_BUNDLE" "$APP_BUNDLE"; then
    info "Removing legacy app bundle: ${LEGACY_APP_BUNDLE}"
    rm -rf "$LEGACY_APP_BUNDLE"
  fi

  remove_login_item "$LEGACY_APP_NAME"

  if [[ -d "$LEGACY_SUPPORT_DIR" ]] && ! same_path "$LEGACY_SUPPORT_DIR" "$SUPPORT_DIR"; then
    info "Migrating Application Support from ${LEGACY_SUPPORT_DIR}..."
    mkdir -p "$SUPPORT_DIR"

    if [[ ! -f "${SUPPORT_DIR}/config.env" && -f "${LEGACY_SUPPORT_DIR}/config.env" ]]; then
      cp "${LEGACY_SUPPORT_DIR}/config.env" "${SUPPORT_DIR}/config.env"
      info "Migrated config.env"
    fi

    for state_file in public-mcp-url.txt public-base-url.txt; do
      if [[ ! -f "${SUPPORT_DIR}/${state_file}" && -f "${LEGACY_SUPPORT_DIR}/${state_file}" ]]; then
        cp "${LEGACY_SUPPORT_DIR}/${state_file}" "${SUPPORT_DIR}/${state_file}"
      fi
    done

    if [[ ! -d "${SUPPORT_DIR}/supergateway-npm" && -d "${LEGACY_SUPPORT_DIR}/supergateway-npm" ]]; then
      mv "${LEGACY_SUPPORT_DIR}/supergateway-npm" "${SUPPORT_DIR}/supergateway-npm"
      info "Migrated supergateway-npm cache"
    fi

    info "Removing legacy Application Support: ${LEGACY_SUPPORT_DIR}"
    rm -rf "$LEGACY_SUPPORT_DIR"
  fi

  if [[ -d "$LEGACY_LOG_DIR" ]] && ! same_path "$LEGACY_LOG_DIR" "$LOG_DIR"; then
    info "Migrating logs from ${LEGACY_LOG_DIR}..."
    mkdir -p "$LOG_DIR"
    for log_file in "$LEGACY_LOG_DIR"/*; do
      [[ -e "$log_file" ]] || continue
      local base
      base="$(basename "$log_file")"
      if [[ ! -e "${LOG_DIR}/${base}" ]]; then
        mv "$log_file" "${LOG_DIR}/${base}"
      fi
    done
    rmdir "$LEGACY_LOG_DIR" 2>/dev/null || true
  fi
}

info "Checking dependencies..."
require_command node "Install Node.js: https://nodejs.org or brew install node"
require_command npx "Ensure npm global bin is on your PATH"

if ! npx -y supergateway --help >/dev/null 2>&1; then
  warn "supergateway could not be fetched via npx (network may be required on first run)"
fi

CUA_DEFAULT="${HOME}/.local/bin/cua-driver"
if [[ ! -x "$CUA_DEFAULT" ]]; then
  warn "cua-driver not found at $CUA_DEFAULT — install it before starting the gateway"
fi

migrate_from_legacy

info "Creating directories..."
mkdir -p "$SUPPORT_DIR" "$LOG_DIR" "${HOME}/Library/LaunchAgents"

info "Installing run scripts..."
install -m 755 "${REPO_ROOT}/scripts/run-gateway.sh" "${SUPPORT_DIR}/run-gateway.sh"
install -m 755 "${REPO_ROOT}/scripts/run-tunnel.sh" "${SUPPORT_DIR}/run-tunnel.sh"
install -m 755 "${REPO_ROOT}/scripts/restart-launchagent.sh" "${SUPPORT_DIR}/restart-launchagent.sh"
install -m 755 "${REPO_ROOT}/scripts/patch-supergateway-sse.js" "${SUPPORT_DIR}/patch-supergateway-sse.js"

cat > "${SUPPORT_DIR}/launchagent-labels.env" <<EOF
GATEWAY_LABEL=${GATEWAY_LABEL}
TUNNEL_LABEL=${TUNNEL_LABEL}
EOF

if [[ ! -f "${SUPPORT_DIR}/config.env" ]]; then
  info "Creating default config at ${SUPPORT_DIR}/config.env"
  install -m 644 "${REPO_ROOT}/config.env.example" "${SUPPORT_DIR}/config.env"
  sed -i '' "s|/Users/ember|${HOME}|g" "${SUPPORT_DIR}/config.env" 2>/dev/null || \
    sed -i "s|/Users/ember|${HOME}|g" "${SUPPORT_DIR}/config.env"
else
  info "Keeping existing config: ${SUPPORT_DIR}/config.env"
  migrate_config_env
fi

if command -v swift >/dev/null 2>&1; then
  info "Building menu bar app..."
  if "${REPO_ROOT}/macos-app/build.sh"; then
    info "Menu bar app built"
  else
    warn "Menu bar build failed — gateway/tunnel will still run via LaunchAgents"
  fi
else
  warn "swift not found — skipping menu bar build (install Xcode CLT for menu bar UI)"
fi

info "Installing ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
cp -R "${REPO_ROOT}/ultragateway.app" "$APP_BUNDLE"
chmod +x "${APP_BUNDLE}/Contents/MacOS/ultragateway"
if [[ -x "${REPO_ROOT}/ultragateway.app/Contents/MacOS/ultragateway-menubar" ]]; then
  chmod +x "${APP_BUNDLE}/Contents/MacOS/ultragateway-menubar"
else
  warn "ultragateway-menubar binary missing — open ${APP_BUNDLE} will not show menu bar icon"
fi

# Build PATH for launchd (minimal environment)
LAUNCHD_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
add_path_dir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] && LAUNCHD_PATH="${dir}:${LAUNCHD_PATH}"
}

for extra in \
  "/opt/homebrew/bin" \
  "/usr/local/bin" \
  "${HOME}/.npm-global/bin" \
  "${HOME}/.local/bin"
do
  add_path_dir "$extra"
done

for cmd in node npx tailscale cloudflared ngrok; do
  if command -v "$cmd" >/dev/null 2>&1; then
    add_path_dir "$(dirname "$(command -v "$cmd")")"
  fi
done

# shellcheck disable=SC1090
source "${SUPPORT_DIR}/config.env" 2>/dev/null || true
if [[ -n "${LAUNCHD_PATH_EXTRA:-}" ]]; then
  LAUNCHD_PATH="${LAUNCHD_PATH_EXTRA}:${LAUNCHD_PATH}"
fi

unload_launch_agent() {
  local label="$1"
  local dest="$2"
  local domain="gui/$(id -u)"
  local target="${domain}/${label}"

  launchctl bootout "$target" 2>/dev/null || true
  launchctl bootout "$domain" "$dest" 2>/dev/null || true
  sleep 0.5
}

ensure_launch_agent_loaded() {
  local label="$1"
  local dest="$2"
  local domain="gui/$(id -u)"
  local target="${domain}/${label}"
  local attempt err

  for attempt in 1 2 3; do
    if launchctl print "$target" >/dev/null 2>&1; then
      unload_launch_agent "$label" "$dest"
    fi

    if err="$(launchctl bootstrap "$domain" "$dest" 2>&1)"; then
      launchctl enable "$target" 2>/dev/null || true
      launchctl kickstart -k "$target" 2>/dev/null || launchctl start "$label" 2>/dev/null || true
      return 0
    fi

    if echo "$err" | grep -qiE 'already loaded|I/O error|Input/output error'; then
      warn "LaunchAgent ${label} bootstrap attempt ${attempt} failed (${err}); unloading and retrying..."
      unload_launch_agent "$label" "$dest"
      sleep 1
      continue
    fi

    die "Failed to load LaunchAgent ${label}: ${err}"
  done

  die "Failed to load LaunchAgent ${label} after 3 attempts"
}

install_launch_agent() {
  local template="$1"
  local dest="$2"
  local label="$3"
  local run_script="$4"

  info "Installing LaunchAgent: ${dest}"
  sed \
    -e "s|__HOME__|${HOME}|g" \
    -e "s|__SUPPORT_DIR__|${SUPPORT_DIR}|g" \
    -e "s|__RUN_SCRIPT__|${SUPPORT_DIR}/run-gateway.sh|g" \
    -e "s|__TUNNEL_SCRIPT__|${SUPPORT_DIR}/run-tunnel.sh|g" \
    -e "s|__CONFIG_FILE__|${SUPPORT_DIR}/config.env|g" \
    -e "s|__LOG_DIR__|${LOG_DIR}|g" \
    -e "s|__PATH__|${LAUNCHD_PATH}|g" \
    "${template}" > "$dest"

  ensure_launch_agent_loaded "$label" "$dest"
}

migrate_launch_agents

install_launch_agent \
  "${REPO_ROOT}/LaunchAgents/com.ultragateway.em.plist" \
  "$GATEWAY_AGENT" \
  "$GATEWAY_LABEL" \
  "${SUPPORT_DIR}/run-gateway.sh"

install_launch_agent \
  "${REPO_ROOT}/LaunchAgents/com.ultragateway.em.tunnel.plist" \
  "$TUNNEL_AGENT" \
  "$TUNNEL_LABEL" \
  "${SUPPORT_DIR}/run-tunnel.sh"

info "Registering hidden login item for ${APP_BUNDLE}..."
remove_login_item "$LEGACY_APP_NAME"
osascript <<EOF 2>/dev/null || warn "Could not add login item automatically — add ${APP_BUNDLE} manually in System Settings > Login Items"
tell application "System Events"
  set appPath to POSIX file "${APP_BUNDLE}"
  if not (exists login item "${APP_NAME}") then
    make login item at end with properties {path:appPath, hidden:true}
  end if
end tell
EOF

PUBLIC_URL="${SUPPORT_DIR}/public-mcp-url.txt"

info ""
info "Installation complete."
info ""
info "  App:            ${APP_BUNDLE}"
info "  Gateway agent:  ${GATEWAY_AGENT}"
info "  Tunnel agent:   ${TUNNEL_AGENT}"
info "  Config:         ${SUPPORT_DIR}/config.env"
info "  Public MCP URL: ${PUBLIC_URL}  (for Poke — see POKE.md)"
info "  Logs:           ${LOG_DIR}/"
info ""
info "Local SSE:  http://127.0.0.1:8000/sse"
info "Tunnel:     TUNNEL_PROVIDER=${TUNNEL_PROVIDER:-tailscale} in config.env"
info ""
info "Commands:"
info "  Status:   launchctl print gui/$(id -u)/${GATEWAY_LABEL}"
info "  Restart:  launchctl kickstart -k gui/$(id -u)/${GATEWAY_LABEL}"
info "  Poke URL: cat ${PUBLIC_URL}"
info "  Remove:   ${REPO_ROOT}/uninstall.sh"
