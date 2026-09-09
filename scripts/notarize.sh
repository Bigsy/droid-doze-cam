#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a profile stored with xcrun notarytool store-credentials}"
APP="$ROOT/dist/PhoneCam.app"
[[ -d "$APP" ]] || { echo "Build and sign with Developer ID Application first." >&2; exit 1; }
[[ "$(cat "$ROOT/dist/build-mode.txt")" == --signed ]] || { echo "Ad-hoc builds cannot be notarized." >&2; exit 1; }
codesign --verify --deep --strict "$APP"
ARCHIVE="$ROOT/dist/PhoneCam-notarization.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ROOT/dist/PhoneCam-macos.zip"
echo "Notarized distribution: $ROOT/dist/PhoneCam-macos.zip"
