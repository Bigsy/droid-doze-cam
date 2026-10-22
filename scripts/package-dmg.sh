#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${SIGN_IDENTITY:?Set your Developer ID Application signing identity}"
[[ "$SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo "A Developer ID Application identity is required." >&2; exit 1; }
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${NOTARY_APPLE_ID:?Set NOTARY_PROFILE or NOTARY_APPLE_ID}"
  : "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD or use NOTARY_PROFILE}"
  : "${TEAM_ID:?Set TEAM_ID}"
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD")
fi

# Package the already-notarized app, so both the DMG and its app have their own tickets.
APP="$ROOT/dist/DroidDozeCam.app"
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/droiddozecam")" == arm64 ]] || { echo "Expected an Apple Silicon app." >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/droiddozecam-dmg.XXXXXX")"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$STAGE/mount" >/dev/null || return; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir "$STAGE/content" "$STAGE/mount"
ditto "$APP" "$STAGE/content/DroidDozeCam.app"
ln -s /Applications "$STAGE/content/Applications"
DMG="$STAGE/DroidDozeCam-macos-arm64.dmg"
hdiutil create -volname DroidDozeCam -srcfolder "$STAGE/content" -fs HFS+ -format UDZO "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait --output-format json > "$STAGE/notary.json"
python3 - "$STAGE/notary.json" <<'PY'
import json
import pathlib
import sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get("status") != "Accepted":
    raise SystemExit(f"DMG notarization {result.get('status', 'failed')}; submission ID {result.get('id', 'unknown')}.")
print("DMG notarization accepted:", result["id"])
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -mountpoint "$STAGE/mount" "$DMG"
MOUNTED=1
[[ "$(readlink "$STAGE/mount/Applications")" == /Applications ]]
codesign --verify --deep --strict "$STAGE/mount/DroidDozeCam.app"
xcrun stapler validate "$STAGE/mount/DroidDozeCam.app"
spctl --assess --type execute --verbose=2 "$STAGE/mount/DroidDozeCam.app"
hdiutil detach "$STAGE/mount"
MOUNTED=0
mv -f "$DMG" "$ROOT/dist/DroidDozeCam-macos-arm64.dmg"
(cd "$ROOT/dist" && shasum -a 256 DroidDozeCam-macos-arm64.dmg > SHA256SUMS.txt)
echo "Notarized disk image: $ROOT/dist/DroidDozeCam-macos-arm64.dmg"
