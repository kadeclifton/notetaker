#!/usr/bin/env bash
# Builds build/Murmur.app. With --install, also copies it to /Applications (or ~/Applications).
#
#   scripts/build-app.sh            # build only
#   scripts/build-app.sh --install  # build, install, and relaunch
#
# Signing: uses the "Murmur Dev" certificate from scripts/setup-signing.sh when it exists, so
# macOS permissions survive rebuilds. Without it the app is ad-hoc signed, which gets a new
# signature every build; --install then clears Murmur's old permission entries (they would look
# granted in System Settings but no longer apply) so macOS asks again cleanly.
# CODESIGN_IDENTITY picks another certificate, or "-" to force ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Murmur.app"
BUNDLE_ID="com.github.kadeclifton.murmur"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"Murmur Dev"'; then
    IDENTITY="Murmur Dev"
else
    IDENTITY="-"
fi

# Apple Silicon only: whisper.cpp is too slow on Intel Macs for dictation to feel instant.
swift build -c release --arch arm64 --product Murmur
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Murmur"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${MURMUR_VERSION:-}" ]]; then
    # Release builds: stamp the version from the tag (v0.2.0 → 0.2.0).
    plutil -replace CFBundleShortVersionString -string "${MURMUR_VERSION#v}" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "${MURMUR_BUILD:-1}" "$APP/Contents/Info.plist"
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

if [[ "$IDENTITY" == "-" ]]; then
    echo "Built $APP (ad-hoc signed)"
    echo "Tip: run scripts/setup-signing.sh once so macOS permissions survive rebuilds."
else
    echo "Built $APP (signed with \"$IDENTITY\")"
fi

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications"
    [[ -w "$DEST" ]] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x Murmur 2>/dev/null || true
    if [[ "$IDENTITY" == "-" ]]; then
        # The old grants belong to the previous signature. Clear them so System Settings
        # shows the truth and macOS asks for the new build.
        for service in Accessibility ListenEvent ScreenCapture; do
            tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
        done
        echo "Cleared Murmur's old permissions; grant them again when asked."
    fi
    rm -rf "$DEST/Murmur.app"
    cp -R "$APP" "$DEST/"
    echo "Installed $DEST/Murmur.app"
    open "$DEST/Murmur.app"
fi
