#!/usr/bin/env bash
# Renders docs/og.png (1200x630) and brand/social-preview.png (1280x640) from card.html.
set -euo pipefail
cd "$(dirname "$0")/../../.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
URL="file://$PWD/brand/tools/cards/card.html"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --virtual-time-budget=3000 --window-size=1200,630 --screenshot="$PWD/docs/og.png" "$URL?w=1200&h=630"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --virtual-time-budget=3000 --window-size=1280,640 --screenshot="$PWD/brand/social-preview.png" "$URL?w=1280&h=640"
