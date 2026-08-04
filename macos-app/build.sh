#!/usr/bin/env bash
# Build ultragateway-menubar and install into ultragateway.app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
APP_BUNDLE="${REPO_ROOT}/ultragateway.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v swift >/dev/null 2>&1 || die "swift not found (install Xcode Command Line Tools)"

info "Building ultragateway-menubar..."
cd "$SCRIPT_DIR"
swift build -c release

BINARY="${BUILD_DIR}/release/ultragateway-menubar"
[[ -x "$BINARY" ]] || die "Build failed: $BINARY not found"

info "Installing menu bar binary into ${APP_BUNDLE}..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
install -m 755 "$BINARY" "${MACOS_DIR}/ultragateway-menubar"
chmod +x "${MACOS_DIR}/ultragateway" 2>/dev/null || true

ASSETS_DIR="${REPO_ROOT}/assets"
if [[ -f "${ASSETS_DIR}/menubar-18.png" && -f "${ASSETS_DIR}/menubar-36.png" ]]; then
  info "Installing menu bar icon resources..."
  install -m 644 "${ASSETS_DIR}/menubar-18.png" "${RESOURCES_DIR}/MenuBarIcon.png"
  install -m 644 "${ASSETS_DIR}/menubar-36.png" "${RESOURCES_DIR}/MenuBarIcon@2x.png"
else
  warn "Menu bar icon PNGs not found in ${ASSETS_DIR} — using system symbol"
fi

info "Menu bar app ready. Re-run install.sh to copy to /Applications."
