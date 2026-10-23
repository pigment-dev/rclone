#!/usr/bin/env bash
# Wraps dist/"PigmentDev rClone.app" in a compressed DMG with a drag-to-Applications layout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="PigmentDev rClone"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/PigmentDev-rClone.dmg"
VOL="$APP_NAME"

[ -d "$APP" ] || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }

STAGE="$(mktemp -d)"
RW="$(mktemp -u).dmg"
trap 'rm -rf "$STAGE" "$RW"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/If the app won't open.txt" <<'EOF'
PigmentDev rClone is free and open source, and not yet notarized by Apple.
After dragging it to Applications, run this once in Terminal:

    xattr -dr com.apple.quarantine "/Applications/PigmentDev rClone.app"

Then open it normally.
EOF

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null

# Lay out the window (icon positions) via Finder; harmless if it fails (e.g. headless CI).
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1; exit}')"
MNT="/Volumes/$VOL"
if [ -d "$MNT" ]; then
    osascript >/dev/null 2>&1 <<EOF || true
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 480}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set position of item "$APP_NAME.app" of container window to {140, 170}
    set position of item "Applications" of container window to {420, 170}
    set position of item "If the app won't open.txt" of container window to {280, 320}
    close
  end tell
end tell
EOF
    sync
fi
[ -n "$DEV" ] && hdiutil detach "$DEV" -quiet || true

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "Built $DMG"
