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

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$UPDATE_LOG"
}

queue_notify() {
  local message="$1"
  local title="${2:-ultragateway}"
  local queue="${SUPPORT_DIR}/notify-queue.jsonl"
  mkdir -p "$SUPPORT_DIR"
  printf '%s\n' "{\"id\":\"$(uuidgen)\",\"title\":\"${title}\",\"body\":\"${message}\",\"subtitle\":\"Update\",\"timestamp\":$(date +%s)}" >> "$queue"
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
