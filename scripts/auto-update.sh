#!/usr/bin/env bash
# Check GitHub for ultragateway updates and run install.sh when main moves.
set -euo pipefail

SUPPORT_DIR="${HOME}/Library/Application Support/ultragateway"
LOG_DIR="${HOME}/Library/Logs/ultragateway"
UPDATE_LOG="${LOG_DIR}/update.log"

# shellcheck disable=SC1091
source "${ULTRAGATEWAY_CONFIG:-${SUPPORT_DIR}/config.env}" 2>/dev/null || true
# shellcheck disable=SC1091
source "${SUPPORT_DIR}/repo.env" 2>/dev/null || true

: "${AUTO_UPDATE_ENABLED:=1}"
: "${AUTO_UPDATE_BRANCH:=main}"
: "${GITHUB_REPO_URL:=https://github.com/embeputer/ultragateway.git}"
: "${ULTRAGATEWAY_REPO_DIR:=}"
: "${APP_RELEASE_UPDATE:=1}"
APP_BUNDLE="/Applications/ultragateway.app"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$UPDATE_LOG"
}

queue_notify() {
  local message="$1"
  local title="${2:-ultragateway}"
  local queue="${SUPPORT_DIR}/notify-queue.jsonl"
  mkdir -p "$SUPPORT_DIR"
  NOTIFY_ID="$(uuidgen)" \
  NOTIFY_TITLE="$title" \
  NOTIFY_BODY="$message" \
  NOTIFY_TIMESTAMP="$(date +%s)" \
  python3 -c '
import json, os

print(
    json.dumps(
        {
            "id": os.environ["NOTIFY_ID"],
            "title": os.environ["NOTIFY_TITLE"],
            "body": os.environ["NOTIFY_BODY"],
            "subtitle": "Update",
            "timestamp": int(os.environ["NOTIFY_TIMESTAMP"]),
        }
    )
)
' >> "$queue"
}

if [[ "$AUTO_UPDATE_ENABLED" == "0" ]]; then
  log "Auto-update disabled (AUTO_UPDATE_ENABLED=0)"
  exit 0
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: '$1' not found — cannot auto-update"
    exit 1
  }
}

require_command git

resolve_repo_dir() {
  if [[ -n "$ULTRAGATEWAY_REPO_DIR" && -d "${ULTRAGATEWAY_REPO_DIR}/.git" ]]; then
    return 0
  fi

  local candidates=(
    "${HOME}/ultragateway"
    "${SUPPORT_DIR}/source"
  )

  for dir in "${candidates[@]}"; do
    if [[ -d "${dir}/.git" ]]; then
      ULTRAGATEWAY_REPO_DIR="$dir"
      return 0
    fi
  done

  return 1
}

clone_repo() {
  local dest="${SUPPORT_DIR}/source"
  log "Cloning ${GITHUB_REPO_URL} to ${dest}"
  rm -rf "$dest"
  git clone --depth 1 --branch "$AUTO_UPDATE_BRANCH" "$GITHUB_REPO_URL" "$dest"
  ULTRAGATEWAY_REPO_DIR="$dest"
  printf 'ULTRAGATEWAY_REPO_DIR=%s\nGITHUB_REPO_URL=%s\n' "$dest" "$GITHUB_REPO_URL" > "${SUPPORT_DIR}/repo.env"
}

installed_app_version() {
  if [[ ! -d "$APP_BUNDLE" ]]; then
    printf '0\n'
    return
  fi
  local v=""
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || true)"
  fi
  [[ -n "$v" ]] || v="$(defaults read "${APP_BUNDLE}/Contents/Info" CFBundleVersion 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s\n' "$v"
}

github_repo_slug() {
  local url="$GITHUB_REPO_URL"
  url="${url%.git}"
  url="${url%/}"
  printf '%s/%s\n' "$(basename "$(dirname "$url")")" "$(basename "$url")"
}

# Install the newest published app zip when it carries a build newer than the
# installed bundle. Covers machines without swift (no local rebuild) and migrates
# older installs onto the Sparkle-enabled app; no-op once versions match.
install_release_app_if_newer() {
  [[ "$APP_RELEASE_UPDATE" != "0" ]] || return 0
  command -v curl >/dev/null 2>&1 || { log "curl missing — skipping release app check"; return 0; }

  local slug json tag build url
  slug="$(github_repo_slug)"
  json="$(curl -fsSL --max-time 30 "https://api.github.com/repos/${slug}/releases/latest" 2>>"$UPDATE_LOG")" || {
    log "No published release found (or API unreachable) — skipping release app check"
    return 0
  }
  tag="$(printf '%s' "$json" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
  build="$(printf '%s' "${tag:-}" | sed -n 's/.*-\([0-9][0-9]*\)$/\1/p')"
  [[ "$build" =~ ^[0-9]+$ ]] || {
    log "Latest release tag '${tag:-unknown}' has no build suffix — skipping release app check"
    return 0
  }
  url="$(printf '%s' "$json" \
    | grep -o '"browser_download_url":[[:space:]]*"[^"]*"' \
    | cut -d'"' -f4 \
    | grep -E '/ultragateway-[0-9.]+\-[0-9]+\.zip$' \
    | head -1)"
  [[ -n "$url" ]] || { log "No app zip asset in latest release — skipping release app check"; return 0; }

  local installed
  installed="$(installed_app_version)"
  if (( installed >= build )); then
    log "Installed app build ${installed} is current (release ${build})"
    return 0
  fi

  log "Downloading app build ${build} from ${tag} (installed: ${installed})"
  local tmp
  tmp="$(mktemp -d)"
  if ! curl -fsSL --max-time 300 -o "${tmp}/app.zip" "$url" 2>>"$UPDATE_LOG"; then
    log "ERROR: app zip download failed"
    rm -rf "$tmp"
    return 1
  fi
  if ! ditto -xk "${tmp}/app.zip" "$tmp" 2>>"$UPDATE_LOG"; then
    log "ERROR: app zip extraction failed"
    rm -rf "$tmp"
    return 1
  fi
  if [[ ! -d "${tmp}/ultragateway.app" ]]; then
    log "ERROR: release zip did not contain ultragateway.app"
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$APP_BUNDLE"
  ditto "${tmp}/ultragateway.app" "$APP_BUNDLE"
  rm -rf "$tmp"

  # Bounce a running menu bar app so the new build takes over.
  if pgrep -f 'ultragateway.app/Contents/MacOS' >/dev/null 2>&1; then
    pkill -f 'ultragateway.app/Contents/MacOS' 2>/dev/null || true
    sleep 1
  fi
  open -g "$APP_BUNDLE" 2>/dev/null || true

  log "App updated to build ${build}"
  queue_notify "ultragateway app updated to build ${build}." "ultragateway update"
}

mkdir -p "$LOG_DIR"

if ! resolve_repo_dir; then
  log "No local git repo found — cloning for auto-updates"
  clone_repo
fi

cd "$ULTRAGATEWAY_REPO_DIR"

if [[ ! -f "./install.sh" ]]; then
  log "ERROR: install.sh missing in ${ULTRAGATEWAY_REPO_DIR}"
  exit 1
fi

REMOTE="origin"
BRANCH="$AUTO_UPDATE_BRANCH"

log "Checking ${GITHUB_REPO_URL} (${BRANCH}) in ${ULTRAGATEWAY_REPO_DIR}"

git remote set-url "$REMOTE" "$GITHUB_REPO_URL" 2>/dev/null || git remote add "$REMOTE" "$GITHUB_REPO_URL"

if ! git fetch "$REMOTE" "$BRANCH" --quiet 2>>"$UPDATE_LOG"; then
  log "ERROR: git fetch failed"
  exit 1
fi

LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "${REMOTE}/${BRANCH}")"

# Keep the app itself on the newest published build even when the checkout did not
# move (bridges older installs onto the Sparkle-enabled releases and covers
# machines without swift that cannot rebuild locally).
install_release_app_if_newer || log "Release app install step failed (non-fatal)"

if [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]]; then
  log "Already up to date (${LOCAL_SHA:0:8})"
  exit 0
fi

log "Update available ${LOCAL_SHA:0:8} → ${REMOTE_SHA:0:8}"
log "Pulling and running install.sh..."

if ! git pull --ff-only "$REMOTE" "$BRANCH" >>"$UPDATE_LOG" 2>&1; then
  log "ERROR: git pull failed — local changes or diverged branch. Fix repo manually."
  queue_notify "Auto-update failed: git pull failed. Check ${UPDATE_LOG}" "ultragateway update"
  exit 1
fi

export AUTO_UPDATE_RUNNING=1
if ./install.sh >>"$UPDATE_LOG" 2>&1; then
  log "Update installed successfully (${REMOTE_SHA:0:8})"
  queue_notify "ultragateway updated to ${REMOTE_SHA:0:8}. Gateway restarted." "ultragateway update"
else
  log "ERROR: install.sh failed after pull"
  queue_notify "Auto-update failed during install. Check ${UPDATE_LOG}" "ultragateway update"
  exit 1
fi
