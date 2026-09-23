#!/usr/bin/env bash
# Sends a signed .app (zipped here), .zip or .dmg to Apple's notary service, waits for the verdict,
# prints Apple's log if it is rejected, and staples the ticket to the .app or .dmg.
#
#   APPLE_ID=… APPLE_APP_PASSWORD=… APPLE_TEAM_ID=… scripts/notarize.sh build/Murmur.app
set -euo pipefail

TARGET="$1"
: "${APPLE_ID:?}" "${APPLE_APP_PASSWORD:?}" "${APPLE_TEAM_ID:?}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
    SUBMIT="$WORK/$(basename "$TARGET" .app).zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

xcrun notarytool submit "$SUBMIT" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --output-format json | tee "$WORK/notary.json"
echo
STATUS="$(plutil -extract status raw "$WORK/notary.json" 2>/dev/null || echo unknown)"
if [[ "$STATUS" != "Accepted" ]]; then
    ID="$(plutil -extract id raw "$WORK/notary.json" 2>/dev/null || true)"
    echo "::error::Notarizing $(basename "$TARGET") finished with status: $STATUS"
    if [[ -n "$ID" ]]; then
        xcrun notarytool log "$ID" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID"
    fi
    exit 1
fi

# Attach the ticket so the app opens without a network check on first launch. A bare .zip cannot
# hold one; its app is stapled separately.
if [[ "$TARGET" == *.app || "$TARGET" == *.dmg ]]; then
    xcrun stapler staple "$TARGET"
fi
