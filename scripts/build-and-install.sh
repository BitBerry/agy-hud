#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_SRC="${ROOT_DIR}/plugin"
MACOS_SRC="${ROOT_DIR}/macos"
BUILD_APP="${ROOT_DIR}/build/AgyHUD.app"

PLUGIN_DEST="${HOME}/.gemini/config/plugins/agy-hud"
DATA_DEST="${HOME}/.gemini/antigravity/plugin_data/agy-hud"
INSTALLED_APP="/Applications/AgyHUD.app"
LEGACY_DATA_APP="${DATA_DEST}/AgyHUD.app"
LEGACY_DOWNLOADS_APP="${HOME}/Downloads/AgyHUD.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Compiling AgyHUD.app..."
rm -rf "${BUILD_APP}"
mkdir -p "${BUILD_APP}/Contents/MacOS" "${BUILD_APP}/Contents/Resources"
cp "${MACOS_SRC}/Resources/Info.plist" "${BUILD_APP}/Contents/Info.plist"

# App icon is rendered from the plugin logo; rebuild it only when the logo changed.
APP_ICON="${MACOS_SRC}/Resources/AppIcon.icns"
if [[ ! -f "${APP_ICON}" || "${PLUGIN_SRC}/assets/logo.svg" -nt "${APP_ICON}" ]]; then
  bash "${ROOT_DIR}/scripts/make-icon.sh"
fi
cp "${APP_ICON}" "${BUILD_APP}/Contents/Resources/AppIcon.icns"

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -framework Cocoa \
  -framework SwiftUI \
  -framework CoreGraphics \
  "${MACOS_SRC}"/Sources/*.swift \
  -o "${BUILD_APP}/Contents/MacOS/AgyHUD"

codesign --force --deep --sign - "${BUILD_APP}"

echo "==> Installing plugin to ${PLUGIN_DEST}..."
mkdir -p "${PLUGIN_DEST}"
rsync -a --delete "${PLUGIN_SRC}/" "${PLUGIN_DEST}/"
chmod 0755 "${PLUGIN_DEST}/scripts/hook.mjs" "${PLUGIN_DEST}/scripts/quota-refresh.mjs"
chmod 0755 "${PLUGIN_SRC}/scripts/hook.mjs" "${PLUGIN_SRC}/scripts/quota-refresh.mjs"

echo "==> Installing AgyHUD.app to ${INSTALLED_APP}..."
mkdir -p "${DATA_DEST}"
chmod 0700 "${DATA_DEST}"

# Gracefully terminate any running AgyHUD instance before replacing binary
if pgrep -x AgyHUD >/dev/null 2>&1; then
  pkill -TERM -x AgyHUD || true
  for _ in {1..20}; do
    pgrep -x AgyHUD >/dev/null 2>&1 || break
    sleep 0.1
  done
  pkill -KILL -x AgyHUD 2>/dev/null || true
fi

# Remove duplicate copies so LaunchServices / Spotlight only list /Applications/AgyHUD.app
for stale in "${LEGACY_DATA_APP}" "${LEGACY_DOWNLOADS_APP}"; do
  if [[ -e "${stale}" ]]; then
    "${LSREGISTER}" -u "${stale}" >/dev/null 2>&1 || true
    rm -rf "${stale}"
  fi
done

rm -rf "${INSTALLED_APP}"
cp -R "${BUILD_APP}" "${INSTALLED_APP}"
"${LSREGISTER}" -u "${BUILD_APP}" >/dev/null 2>&1 || true
rm -rf "${BUILD_APP}"
"${LSREGISTER}" -f "${INSTALLED_APP}" >/dev/null 2>&1 || true

echo "==> Validating plugin with agy plugin validate --strict..."
agy plugin validate --strict "${PLUGIN_DEST}"

echo "==> Done!"
