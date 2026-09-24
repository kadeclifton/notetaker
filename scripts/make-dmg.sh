#!/usr/bin/env bash
# Packs build/Murmur.app into a disk image that opens as a window: the app, an arrow, and an
# Applications shortcut to drag it onto, like most Mac downloads.
#
#   scripts/make-dmg.sh [output.dmg]     # default build/Murmur.dmg
#
# Uses create-dmg (brew install create-dmg) for the window layout. Without it, or if its Finder
# scripting fails (it needs a logged-in session), makes a plain image with the same two items.
# Signs the image when CODESIGN_IDENTITY is a Developer ID; notarizing is up to the caller.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Murmur.app"
OUT="${1:-$ROOT/build/Murmur.dmg}"
[[ -d "$APP" ]] || { echo "No $APP; run scripts/build-app.sh first." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/Murmur.app"
rm -f "$OUT"

plain_dmg() {
    ln -s /Applications "$WORK/stage/Applications"
    hdiutil create -volname "Murmur" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
    echo "Made $OUT (plain window: no background)."
}

if command -v create-dmg >/dev/null 2>&1; then
    # One TIFF with both resolutions, so the background is sharp on Retina screens.
    tiffutil -cathidpicheck "$ROOT/Resources/dmg-background.png" "$ROOT/Resources/dmg-background@2x.png" \
        -out "$WORK/background.tiff" >/dev/null
    # Positions match scripts/make-dmg-background.py.
    if create-dmg --volname "Murmur" --volicon "$ROOT/Resources/AppIcon.icns" \
            --background "$WORK/background.tiff" --window-pos 200 120 --window-size 660 400 \
            --icon-size 128 --text-size 13 --icon "Murmur.app" 170 190 --hide-extension "Murmur.app" \
            --app-drop-link 490 190 "$OUT" "$WORK/stage" >"$WORK/create-dmg.log" 2>&1; then
        echo "Made $OUT."
    else
        echo "create-dmg could not lay out the window; making a plain image instead:" >&2
        tail -5 "$WORK/create-dmg.log" >&2 || true
        rm -f "$OUT"
        plain_dmg
    fi
else
    plain_dmg
fi

if [[ "${CODESIGN_IDENTITY:-}" == "Developer ID Application:"* ]]; then
    # Apple's timestamp server now and then does not answer; try a few times.
    for attempt in 1 2 3 4; do
        codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$OUT" && break
        [[ $attempt == 4 ]] && { echo "Signing $OUT failed 4 times." >&2; exit 1; }
        sleep $((attempt * 10))
    done
    echo "Signed $OUT."
fi
