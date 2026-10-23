#!/bin/bash
# Build the app and install it into /Applications, replacing the running copy.
# The built bundle is removed from dist/ afterwards so Spotlight and Launchpad
# only show the installed app (the .zip and .dmg stay).
set -euo pipefail
cd "$(dirname "$0")/.."
APP_NAME="PigmentDev rClone.app"
DEST="/Applications/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

./scripts/build-app.sh >/dev/null

osascript -e 'quit app id "com.pigmentdev.rclone"' >/dev/null 2>&1 || true
sleep 1
pkill -x PigmentDevRClone 2>/dev/null || true
pkill -x pdrcloned 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x pdrcloned >/dev/null || pgrep -x PigmentDevRClone >/dev/null || break; sleep 0.5; done

rm -rf "$DEST"
ditto "dist/$APP_NAME" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
"$LSREGISTER" -u "$PWD/dist/$APP_NAME" 2>/dev/null || true
rm -rf "dist/$APP_NAME"
"$LSREGISTER" -f "$DEST" 2>/dev/null || true

open "$DEST"
echo "Installed $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString) to $DEST"
