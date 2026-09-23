#!/usr/bin/env bash
# Builds build/Murmur.app. With --install, also copies it to /Applications (or ~/Applications).
#
#   scripts/build-app.sh            # build only
#   scripts/build-app.sh --install  # build, install, and relaunch
#
# Signing: by default the app is ad-hoc signed. macOS ties Accessibility and Input Monitoring
# grants to the signature, and an ad-hoc signature changes on every build, so you would have to
# re-grant after each rebuild. Set CODESIGN_IDENTITY to a certificate in your keychain (a free
# self-signed "Code Signing" certificate is enough, see README) to keep permissions across builds.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Murmur.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release --product Murmur
BIN="$(swift build -c release --show-bin-path)/Murmur"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --identifier com.github.kadeclifton.murmur "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications"
    [[ -w "$DEST" ]] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x Murmur 2>/dev/null || true
    rm -rf "$DEST/Murmur.app"
    cp -R "$APP" "$DEST/"
    echo "Installed $DEST/Murmur.app"
    open "$DEST/Murmur.app"
fi
