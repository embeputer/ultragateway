#!/usr/bin/env bash
# Restart a user LaunchAgent by label, with bootstrap fallback when kickstart fails.
set -euo pipefail

label="${1:?usage: restart-launchagent.sh <label>}"
uid="$(id -u)"
domain="gui/${uid}"
service="${domain}/${label}"
plist="${HOME}/Library/LaunchAgents/${label}.plist"

unload_service() {
  launchctl bootout "$service" 2>/dev/null || true
  launchctl bootout "$domain" "$plist" 2>/dev/null || true
  sleep 0.5
}

kickstart_service() {
  launchctl kickstart -k "$service"
}

if kickstart_service 2>/dev/null; then
  exit 0
fi

if [[ ! -f "$plist" ]]; then
  printf 'restart-launchagent: no plist at %s\n' "$plist" >&2
  exit 1
fi

attempt=0
while (( attempt < 3 )); do
  attempt=$((attempt + 1))
  unload_service
  if err="$(launchctl bootstrap "$domain" "$plist" 2>&1)"; then
    launchctl enable "$service" 2>/dev/null || true
    kickstart_service 2>/dev/null || launchctl start "$label" 2>/dev/null || true
    exit 0
  fi
  if ! echo "$err" | grep -qiE 'already loaded|I/O error|Input/output error'; then
    printf 'restart-launchagent: bootstrap failed for %s: %s\n' "$label" "$err" >&2
    exit 1
  fi
  sleep 1
done

printf 'restart-launchagent: bootstrap failed for %s after 3 attempts\n' "$label" >&2
exit 1
