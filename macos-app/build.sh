#!/usr/bin/env bash
# Build ultragateway-menubar and install into ultragateway.app bundle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
APP_BUNDLE="${REPO_ROOT}/ultragateway.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"
FRAMEWORKS_DIR="${APP_BUNDLE}/Contents/Frameworks"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"

UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    *) printf 'error: unknown argument %s\n' "$arg" >&2; exit 2 ;;
  esac
done

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v swift >/dev/null 2>&1 || die "swift not found (install Xcode Command Line Tools)"

SWIFT_BUILD_ARGS=(-c release)
if [[ "$UNIVERSAL" == "1" ]]; then
  SWIFT_BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

info "Building ultragateway-menubar ($([[ "$UNIVERSAL" == "1" ]] && echo universal || echo native))..."
cd "$SCRIPT_DIR"
swift build "${SWIFT_BUILD_ARGS[@]}"

BIN_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BINARY="${BIN_PATH}/ultragateway-menubar"
[[ -x "$BINARY" ]] || die "Build failed: $BINARY not found"

info "Installing menu bar binary into ${APP_BUNDLE}..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
install -m 755 "$BINARY" "${MACOS_DIR}/ultragateway-menubar"
chmod +x "${MACOS_DIR}/ultragateway" 2>/dev/null || true
# SwiftPM links Sparkle via @rpath; inside a .app bundle it lives in Contents/Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/ultragateway-menubar" 2>/dev/null || true

ASSETS_DIR="${REPO_ROOT}/assets"
if [[ -f "${ASSETS_DIR}/menubar-18.png" && -f "${ASSETS_DIR}/menubar-36.png" ]]; then
  info "Installing menu bar icon resources..."
  install -m 644 "${ASSETS_DIR}/menubar-18.png" "${RESOURCES_DIR}/MenuBarIcon.png"
  install -m 644 "${ASSETS_DIR}/menubar-36.png" "${RESOURCES_DIR}/MenuBarIcon@2x.png"
else
  warn "Menu bar icon PNGs not found in ${ASSETS_DIR} — using system symbol"
fi

info "Embedding Sparkle.framework..."
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework"
SPARKLE_SRC="${BIN_PATH}/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
  SPARKLE_SRC="$(find "${BUILD_DIR}" -name Sparkle.framework -type d -maxdepth 6 2>/dev/null | head -1)"
fi
[[ -d "$SPARKLE_SRC" ]] || die "Sparkle.framework not found next to build products (resolved bin path: ${BIN_PATH})"
ditto "$SPARKLE_SRC" "${FRAMEWORKS_DIR}/Sparkle.framework"

info "Staging installer payload (Contents/Resources/installer)..."
PAYLOAD_DIR="${RESOURCES_DIR}/installer"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
for item in install.sh uninstall.sh config.env.example README.md POKE.md scripts LaunchAgents native-mcp assets; do
  if [[ -e "${REPO_ROOT}/${item}" ]]; then
    ditto "${REPO_ROOT}/${item}" "${PAYLOAD_DIR}/${item}"
  fi
done
rm -rf "${PAYLOAD_DIR}/native-mcp/node_modules" "${PAYLOAD_DIR}/native-mcp/package-lock.json"
find "$PAYLOAD_DIR" -name '.DS_Store' -delete 2>/dev/null || true
chmod +x "${PAYLOAD_DIR}/install.sh" "${PAYLOAD_DIR}/uninstall.sh" "${PAYLOAD_DIR}/scripts/"*.sh 2>/dev/null || true

# Stamp CFBundleVersion with the git commit count when building from a checkout,
# so locally built apps compare correctly against published release builds
# (the release workflow stamps the same counter for the same commit).
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BUILD_VERSION="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || true)"
  if [[ -n "${BUILD_VERSION:-}" && -x /usr/libexec/PlistBuddy ]]; then
    info "Stamping CFBundleVersion=${BUILD_VERSION}..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_VERSION}" "$INFO_PLIST" \
      || warn "Could not stamp CFBundleVersion in ${INFO_PLIST}"
  fi
fi

info "Ad-hoc signing app bundle (required for notification prompts)..."
# Sign nested code inside-out: framework helpers, framework, launcher, binary, bundle.
# SwiftPM linker-signs the binary as "ultragateway-menubar" without binding Info.plist;
# the bundle-level sign binds Info.plist so UserNotifications sees CFBundleIdentifier.
if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
  for nested in \
    "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Autoupdate" \
    "${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B/Updater.app"; do
    [[ -e "$nested" ]] && codesign --force --sign - "$nested" >/dev/null 2>&1 || true
  done
  codesign --force --sign - "${FRAMEWORKS_DIR}/Sparkle.framework" >/dev/null 2>&1 || true
fi
if [[ -f "${MACOS_DIR}/ultragateway" ]]; then
  codesign --force --sign - --identifier "com.ultragateway.em.launcher" "${MACOS_DIR}/ultragateway" >/dev/null 2>&1 || true
fi
codesign --force --sign - --identifier "com.ultragateway.em" "${MACOS_DIR}/ultragateway-menubar" >/dev/null
codesign --force --deep --sign - --identifier "com.ultragateway.em" "${APP_BUNDLE}" >/dev/null
codesign -dv --verbose=2 "${APP_BUNDLE}" 2>&1 | grep -E 'Identifier=|Info\.plist|Signature=' || true

info "Menu bar app ready. Re-run install.sh to copy to /Applications."
