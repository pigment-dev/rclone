#!/usr/bin/env bash
# Builds "dist/PigmentDev rClone.app" (+ zip, optional .sig, DMG) from the SwiftPM package.
#   UNIVERSAL=1        build arm64 + x86_64 (app via SwiftPM, daemon via go + lipo)
#   SIGN_IDENTITY=...  code-signing identity (default: ad-hoc "-")
#   NO_DMG=1           skip the DMG
#   NO_DAEMON=1        don't build/embed pdrcloned
#   CONFIG=debug       swift build configuration (default release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
APP_NAME="PigmentDev rClone"
EXE="PigmentDevRClone"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONFIG="${CONFIG:-release}"
cd "$ROOT"

if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); GOARCHES=(arm64 amd64); else ARCHS=(--arch arm64); GOARCHES=(arm64); fi

echo "==> swift build -c $CONFIG ${ARCHS[*]}"
swift build -c "$CONFIG" "${ARCHS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts" "$APP/Contents/Library/LaunchAgents"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Version stamping from the repo VERSION file when present.
if [ -f "$REPO/VERSION" ]; then
    V="$(tr -d '[:space:]' < "$REPO/VERSION")"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"; fi
if [ -n "${PDRCLONE_PUBLIC_KEY:-}" ]; then /usr/libexec/PlistBuddy -c "Set :PDRClonePublicEDKey $PDRCLONE_PUBLIC_KEY" "$APP/Contents/Info.plist"; fi

# Fonts (Red Hat for English, Vazirmatn for Persian; both OFL) — registered at launch with CTFontManager.
cp Resources/Fonts/*.ttf Resources/Fonts/*OFL.txt "$APP/Contents/Resources/Fonts/" 2>/dev/null || true

# Strings: compile the String Catalog into <lang>.lproj/Localizable.strings (+ .stringsdict).
# xcstringstool only writes languages that have values, so the English keys are stored as English
# values too; en.lproj must exist or macOS won't treat English as a localization.
if [ -f Resources/Localizable.xcstrings ]; then
    if ! xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"; then
        echo "error: couldn't compile Localizable.xcstrings" >&2; exit 1
    fi
    for lang in en fa; do
        if [ ! -f "$APP/Contents/Resources/$lang.lproj/Localizable.strings" ]; then
            echo "error: $lang.lproj/Localizable.strings is missing from the app bundle" >&2; exit 1
        fi
    done
fi

# App icon: Icon Composer bundle → Assets.car + icns, else a prebuilt AppIcon.icns (made by the brand agent).
ICON_TMP="$(mktemp -d)"
if [ -d Resources/AppIcon.icon ] && xcrun actool Resources/AppIcon.icon --compile "$ICON_TMP" --app-icon AppIcon --platform macosx \
        --minimum-deployment-target 14.0 --output-partial-info-plist "$ICON_TMP/p.plist" >/dev/null 2>&1; then
    cp "$ICON_TMP"/Assets.car "$ICON_TMP"/AppIcon.icns "$APP/Contents/Resources/" 2>/dev/null || true
elif [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$REPO/brand/AppIcon.icns" ]; then
    cp "$REPO/brand/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "note: no AppIcon yet (Resources/AppIcon.icns or brand/AppIcon.icns)"
fi
rm -rf "$ICON_TMP"

# Daemon and CLI: build ../core/cmd/{pdrcloned,pdrclone} with Go (if available) into Contents/MacOS/.
if [ "${NO_DAEMON:-0}" != "1" ]; then
    if command -v go >/dev/null 2>&1 && [ -d "$REPO/core/cmd/pdrcloned" ] && ls "$REPO/core/cmd/pdrcloned"/*.go >/dev/null 2>&1; then
        GO_TMP="$(mktemp -d)"
        GO_LDFLAGS="-s -w -X github.com/pigment-dev/rclone/core/internal/version.Version=${V:-0.0.0}"
        for bin in pdrcloned pdrclone; do
            OUTS=()
            ok=1
            for ga in "${GOARCHES[@]}"; do
                echo "==> go build $bin ($ga)"
                if (cd "$REPO/core" && CGO_ENABLED="${CGO_ENABLED:-0}" GOOS=darwin GOARCH="$ga" \
                        go build -trimpath -ldflags "$GO_LDFLAGS" -o "$GO_TMP/$bin-$ga" ./cmd/$bin); then
                    OUTS+=("$GO_TMP/$bin-$ga")
                else
                    ok=0; echo "warning: go build $bin for $ga failed — the app will run without it"
                fi
            done
            if [ "$ok" = "1" ]; then
                if [ "${#OUTS[@]}" -gt 1 ]; then lipo -create "${OUTS[@]}" -output "$APP/Contents/MacOS/$bin"
                else cp "${OUTS[0]}" "$APP/Contents/MacOS/$bin"; fi
                chmod +x "$APP/Contents/MacOS/$bin"
            fi
        done
        rm -rf "$GO_TMP"
    else
        echo "note: skipping pdrcloned (go not found or core/cmd/pdrcloned has no sources yet)"
    fi
fi

# LaunchAgent for SMAppService.agent(plistName:)
if [ -f "$REPO/core/packaging/macos/com.pigmentdev.rclone.daemon.plist" ]; then
    cp "$REPO/core/packaging/macos/com.pigmentdev.rclone.daemon.plist" "$APP/Contents/Library/LaunchAgents/"
else
    cp Resources/com.pigmentdev.rclone.daemon.plist "$APP/Contents/Library/LaunchAgents/"
fi

# Sign inside-out: nested executables first, then the bundle (no --deep).
SIGN="${SIGN_IDENTITY:--}"
if [ -f "$APP/Contents/MacOS/pdrcloned" ]; then
    codesign --force --options runtime --timestamp=none --identifier com.pigmentdev.rclone.daemon --sign "$SIGN" "$APP/Contents/MacOS/pdrcloned"
fi
if [ -f "$APP/Contents/MacOS/pdrclone" ]; then
    codesign --force --options runtime --timestamp=none --identifier com.pigmentdev.rclone.cli --sign "$SIGN" "$APP/Contents/MacOS/pdrclone"
fi
codesign --force --options runtime --timestamp=none --entitlements Resources/PigmentDevRClone.entitlements --sign "$SIGN" "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1

cd "$DIST"
ZIP="PigmentDev-rClone.zip"
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent "$APP_NAME.app" "$ZIP"
if [ -f "${PDRCLONE_KEY:-$HOME/.config/pdrclone/ed25519.key}" ]; then
    swift "$ROOT/scripts/release-key.swift" sign "$DIST/$ZIP"
fi

if [ "${NO_DMG:-0}" != "1" ]; then "$ROOT/scripts/make-dmg.sh"; fi

echo "Built $APP (signed with: ${SIGN})"
lipo -info "$APP/Contents/MacOS/$EXE"
[ -f "$APP/Contents/MacOS/pdrcloned" ] && lipo -info "$APP/Contents/MacOS/pdrcloned" || true
