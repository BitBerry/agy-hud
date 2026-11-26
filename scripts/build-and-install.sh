#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_SRC="${ROOT_DIR}/plugin"
MACOS_SRC="${ROOT_DIR}/macos"
BUILD_APP="${ROOT_DIR}/build/AgyHUD.app"

PLUGIN_DEST="${HOME}/.gemini/config/plugins/agy-hud"
DATA_DEST="${HOME}/.gemini/antigravity/plugin_data/agy-hud"
INSTALLED_APP="${DATA_DEST}/AgyHUD.app"
DOWNLOADS_APP="${HOME}/Downloads/AgyHUD.app"

echo "==> Compiling AgyHUD.app..."
rm -rf "${BUILD_APP}"
mkdir -p "${BUILD_APP}/Contents/MacOS" "${BUILD_APP}/Contents/Resources"
cp "${MACOS_SRC}/Resources/Info.plist" "${BUILD_APP}/Contents/Info.plist"

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

rm -rf "${INSTALLED_APP}"
cp -R "${BUILD_APP}" "${INSTALLED_APP}"

echo "==> Copying build artifact to ${DOWNLOADS_APP}..."
rm -rf "${DOWNLOADS_APP}"
cp -R "${BUILD_APP}" "${DOWNLOADS_APP}"

echo "==> Validating plugin with agy plugin validate --strict..."
agy plugin validate --strict "${PLUGIN_DEST}"

echo "==> Done!"
