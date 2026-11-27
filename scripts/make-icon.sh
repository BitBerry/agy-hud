#!/usr/bin/env bash
# Regenerates macos/Resources/AppIcon.icns from plugin/assets/logo.svg so the
# plugin logo and the AgyHUD.app icon stay one design. Uses only tools that
# ship with macOS (sips renders the SVG, iconutil packs the .icns).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="${ROOT_DIR}/plugin/assets/logo.svg"
ICNS="${ROOT_DIR}/macos/Resources/AppIcon.icns"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
ICONSET="${WORK_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET}"

render() {
  local px="$1" name="$2"
  sips -s format png -z "${px}" "${px}" "${SVG}" --out "${ICONSET}/${name}" >/dev/null
}

for pt in 16 32 128 256 512; do
  render "${pt}" "icon_${pt}x${pt}.png"
  render "$((pt * 2))" "icon_${pt}x${pt}@2x.png"
done

iconutil -c icns "${ICONSET}" -o "${ICNS}"
echo "Wrote ${ICNS}"
