#!/usr/bin/env bash
# Builds build/Murmur.app. With --install, also copies it to /Applications (or ~/Applications).
#
#   scripts/build-app.sh            # build only
#   scripts/build-app.sh --install  # build, install, and relaunch
#
# Signing, first one found:
#   1. A "Developer ID Application" certificate (Apple Developer account): signed with the hardened
#      runtime, ready for notarization, so it opens on any Mac without warnings. Releases use this.
#   2. The "Murmur Dev" certificate from scripts/setup-signing.sh, so macOS permissions survive
#      rebuilds on your own Mac.
#   3. Ad-hoc, which gets a new signature every build; --install then clears Murmur's old permission
#      entries (they would look granted in System Settings but no longer apply) so macOS asks again.
# CODESIGN_IDENTITY picks another certificate, or "-" to force ad-hoc.
#
# whisper.cpp: if scripts/build-whisper.sh has built it (build/whisper/bin), whisper-server and
# whisper-cli go inside the app, so dictation works without Homebrew and can use the Neural Engine.
# Releases always include them; set MURMUR_REQUIRE_WHISPER=1 to fail when they are missing.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Murmur.app"
BUNDLE_ID="com.github.kadeclifton.murmur"

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVELOPER_ID="$(grep -o '"Developer ID Application: [^"]*"' <<<"$IDENTITIES" | head -1 | tr -d '"' || true)"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif [[ -n "$DEVELOPER_ID" ]]; then
    IDENTITY="$DEVELOPER_ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"Murmur Dev"'; then
    IDENTITY="Murmur Dev"
else
    IDENTITY="-"
fi

# Apple Silicon only: whisper.cpp is too slow on Intel Macs for dictation to feel instant.
swift build -c release --arch arm64 --product Murmur
swift build -c release --arch arm64 --product MurmurWidgets
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/Murmur"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
# Local symbols are only for debugging; crash reports still name the app's own functions.
strip -x "$APP/Contents/MacOS/Murmur"
WHISPER_BIN="$ROOT/build/whisper/bin"
HELPERS=()
if [[ -x "$WHISPER_BIN/whisper-server" && -x "$WHISPER_BIN/whisper-cli" ]]; then
    for helper in whisper-server whisper-cli; do
        cp "$WHISPER_BIN/$helper" "$APP/Contents/MacOS/$helper"
        HELPERS+=("$APP/Contents/MacOS/$helper")
    done
elif [[ "${MURMUR_REQUIRE_WHISPER:-}" == 1 ]]; then
    echo "build/whisper/bin is missing; run scripts/build-whisper.sh first." >&2
    exit 1
else
    echo "Note: no bundled whisper.cpp (run scripts/build-whisper.sh to include it); Murmur will use Homebrew's." >&2
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# The desktop widget: an app extension, which macOS finds inside the app and runs sandboxed.
APPEX="$APP/Contents/PlugIns/MurmurWidgets.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN_DIR/MurmurWidgets" "$APPEX/Contents/MacOS/MurmurWidgets"
strip -x "$APPEX/Contents/MacOS/MurmurWidgets"
cp "$ROOT/Resources/Widgets-Info.plist" "$APPEX/Contents/Info.plist"

# macOS 26 icons (light, dark, clear, tinted) are compiled from Resources/AppIcon.icon by Xcode's
# actool, which needs Xcode 26 running on macOS 26. Otherwise the flat AppIcon.icns above is used,
# which works on every macOS.
ICON_NOTE="flat icon only (dark and tinted icons need Xcode 26 on macOS 26)"
if xcrun --find actool >/dev/null 2>&1; then
    ICON_TMP="$(mktemp -d)"
    if xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$ICON_TMP" \
            --platform macosx --target-device mac --minimum-deployment-target 14.0 \
            --app-icon AppIcon --output-partial-info-plist "$ICON_TMP/partial.plist" \
            --output-format human-readable-text --errors >"$ICON_TMP/actool.log" 2>&1 \
            && [[ -f "$ICON_TMP/Assets.car" ]]; then
        cp "$ICON_TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
        [[ -f "$ICON_TMP/AppIcon.icns" ]] && cp "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
        ICON_NOTE="light, dark, clear and tinted icons"
    else
        echo "Note: actool could not compile AppIcon.icon; using the flat icon." >&2
        sed 's/^/  actool: /' "$ICON_TMP/actool.log" >&2 || true
    fi
    rm -rf "$ICON_TMP"
fi
if [[ -n "${MURMUR_VERSION:-}" ]]; then
    # Release builds: stamp the version from the tag (v0.2.0 → 0.2.0), on the widget too.
    for plist in "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"; do
        plutil -replace CFBundleShortVersionString -string "${MURMUR_VERSION#v}" "$plist"
        plutil -replace CFBundleVersion -string "${MURMUR_BUILD:-1}" "$plist"
    done
fi

# The app group Murmur shares with its widget (Murmur writes the numbers, the widget reads them).
# On a Mac its name must start with the Team ID of the certificate that signs both, so only
# Developer ID builds get one; other builds' widget asks you to open Murmur.
ENTITLEMENTS_DIR="$(mktemp -d)"
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT
APP_ENTITLEMENTS="$ENTITLEMENTS_DIR/Murmur.entitlements"
WIDGET_ENTITLEMENTS="$ENTITLEMENTS_DIR/MurmurWidgets.entitlements"
cp "$ROOT/Resources/Murmur.entitlements" "$APP_ENTITLEMENTS"
cp "$ROOT/Resources/MurmurWidgets.entitlements" "$WIDGET_ENTITLEMENTS"
APP_GROUP=""
if [[ "$IDENTITY" == "Developer ID Application:"* && "$IDENTITY" =~ \(([A-Z0-9]{10})\)$ ]]; then
    APP_GROUP="${BASH_REMATCH[1]}.$BUNDLE_ID"
    for file in "$APP_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"; do
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" \
            -c "Add :com.apple.security.application-groups:0 string $APP_GROUP" "$file"
    done
    for plist in "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"; do
        /usr/libexec/PlistBuddy -c "Add :MurmurAppGroup string $APP_GROUP" "$plist"
    done
fi
# The secure timestamp comes from Apple's server, which now and then does not answer.
sign_with_retry() {
    for attempt in 1 2 3 4; do
        if codesign "$@"; then
            return 0
        fi
        if [[ $attempt == 4 ]]; then
            echo "Signing failed 4 times (Apple's timestamp server may be down); try again later." >&2
            exit 1
        fi
        echo "Signing failed; retrying in $((attempt * 10)) s (attempt $((attempt + 1)) of 4)." >&2
        sleep $((attempt * 10))
    done
}

# Helpers and the widget first: the app's signature seals them as they are.
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    # What notarization requires: hardened runtime, a secure timestamp, and the entitlements
    # the hardened runtime would otherwise withhold (the microphone).
    for helper in ${HELPERS[@]+"${HELPERS[@]}"}; do
        sign_with_retry --force --sign "$IDENTITY" --options runtime --timestamp "$helper"
    done
    sign_with_retry --force --sign "$IDENTITY" --options runtime --timestamp \
        --entitlements "$WIDGET_ENTITLEMENTS" "$APPEX"
    sign_with_retry --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp \
        --entitlements "$APP_ENTITLEMENTS" "$APP"
else
    for helper in ${HELPERS[@]+"${HELPERS[@]}"}; do
        codesign --force --sign "$IDENTITY" "$helper"
    done
    codesign --force --sign "$IDENTITY" --entitlements "$WIDGET_ENTITLEMENTS" "$APPEX"
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi

[[ ${#HELPERS[@]} -gt 0 ]] && ICON_NOTE="$ICON_NOTE, whisper.cpp $(cat "$ROOT/build/whisper/VERSION") with Core ML"
if [[ -n "$APP_GROUP" ]]; then
    ICON_NOTE="$ICON_NOTE, desktop widget sharing $APP_GROUP"
else
    ICON_NOTE="$ICON_NOTE, desktop widget (its numbers need a Developer ID build)"
fi
if [[ "$IDENTITY" == "-" ]]; then
    echo "Built $APP (ad-hoc signed, $ICON_NOTE)"
    echo "Tip: run scripts/setup-signing.sh once so macOS permissions survive rebuilds."
else
    echo "Built $APP (signed with \"$IDENTITY\", $ICON_NOTE)"
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
