#!/usr/bin/env bash
# Regenerates Assets/icons/*.png and AppIcon.icns from the SVG sources. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/Assets/icons"
rsvg-convert -w 18 -h 18 menubar.svg -o menubar.png
rsvg-convert -w 36 -h 36 menubar.svg -o menubar@2x.png
rsvg-convert -w 1024 -h 1024 AppIcon.svg -o AppIcon-1024.png
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
    rsvg-convert -w $s -h $s AppIcon.svg -o "AppIcon.iconset/icon_${s}x${s}.png"
    rsvg-convert -w $((s * 2)) -h $((s * 2)) AppIcon.svg -o "AppIcon.iconset/icon_${s}x${s}@2x.png"
done
python3 "$ROOT/Scripts/strip_png.py" menubar.png menubar@2x.png AppIcon-1024.png AppIcon.iconset/*.png
mkdir -p "$ROOT/docs"
cp AppIcon-1024.png "$ROOT/docs/AppIcon-1024.png"
iconutil -c icns AppIcon.iconset -o AppIcon.icns
python3 "$ROOT/Scripts/strip_png.py" AppIcon.icns
rm -rf AppIcon.iconset
