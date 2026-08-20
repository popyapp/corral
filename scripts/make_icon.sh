#!/bin/bash
# Regenerates Assets/AppIcon.icns (and the square marketing PNG) from the SVG
# sources. Needs librsvg (`brew install librsvg`); iconutil ships with macOS.
# The generated .icns is committed, so normal builds don't need this script.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
  echo "rsvg-convert not found — brew install librsvg" >&2
  exit 1
}

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" Assets/icon.svg > "$ICONSET/icon_${size}x${size}.png"
  double=$((size * 2))
  rsvg-convert -w "$double" -h "$double" Assets/icon.svg > "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o Assets/AppIcon.icns
rsvg-convert -w 1024 -h 1024 Assets/icon-square.svg > Assets/icon-square-1024.png

echo "Done: Assets/AppIcon.icns and Assets/icon-square-1024.png"
