#!/usr/bin/env bash
# Rasterises the brand SVGs: brand/png/*, mac/Resources/AppIcon.icns,
# mac/Resources/MenuBarIcon*.pdf and the favicons in docs/.
# Needs: rsvg-convert (brew install librsvg) and iconutil (Xcode CLT).
set -euo pipefail
cd "$(dirname "$0")/../.."
B=brand
mkdir -p "$B/png" docs mac/Resources

# app icon PNGs
for s in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $s -h $s "$B/app-icon.svg" -o "$B/png/app-icon-$s.png"
done
# mark PNGs (transparent)
for s in 64 128 256 512 1024; do
  rsvg-convert -w $s -h $s "$B/logo-mark.svg" -o "$B/png/logo-mark-$s.png"
  rsvg-convert -w $s -h $s "$B/logo-mark-dark.svg" -o "$B/png/logo-mark-dark-$s.png"
done
rsvg-convert -w 1600 "$B/logo-horizontal.svg" -o "$B/png/logo-horizontal-1600.png"
rsvg-convert -w 1600 "$B/logo-horizontal-dark.svg" -o "$B/png/logo-horizontal-dark-1600.png"

# .icns
TMP=$(mktemp -d)
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s "$B/app-icon.svg" -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) "$B/app-icon.svg" -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o mac/Resources/AppIcon.icns
rm -rf "$TMP"

# menu bar template PDFs (18 x 18 pt)
rsvg-convert -f pdf --dpi-x 72 --dpi-y 72 "$B/menubar-template.svg" -o mac/Resources/MenuBarIcon.pdf
rsvg-convert -f pdf --dpi-x 72 --dpi-y 72 "$B/menubar-template-attention.svg" -o mac/Resources/MenuBarIcon-Attention.pdf
rsvg-convert -f pdf --dpi-x 72 --dpi-y 72 "$B/menubar-template-paused.svg" -o mac/Resources/MenuBarIcon-Paused.pdf

# favicons
cp "$B/favicon.svg" docs/favicon.svg
rsvg-convert -w 32 -h 32 "$B/app-icon.svg" -o docs/favicon-32.png
rsvg-convert -w 180 -h 180 "$B/apple-touch-icon.svg" -o docs/apple-touch-icon.png
echo "exported"
