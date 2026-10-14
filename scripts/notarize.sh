#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${NOTARY_APPLE_ID:?Set NOTARY_PROFILE or NOTARY_APPLE_ID for notarization}"
  [[ -n "${NOTARY_PASSWORD:-}" ]] || { echo "Missing CI notarization credential." >&2; exit 1; }
  : "${TEAM_ID:?Set TEAM_ID for CI notarization}"
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD")
fi
APP="$ROOT/dist/DroidDozeCam.app"
[[ -d "$APP" ]] || { echo "Build and sign with Developer ID Application first." >&2; exit 1; }
[[ "$(cat "$ROOT/dist/build-mode.txt")" == --signed ]] || { echo "Ad-hoc builds cannot be notarized." >&2; exit 1; }
EXT="$APP/Contents/Library/SystemExtensions/com.hedworth.usbwakecam.camera.systemextension"
[[ -d "$EXT" ]] || { echo "Camera extension is missing from the app." >&2; exit 1; }
for EXECUTABLE in "$APP/Contents/MacOS/phonecam" "$EXT/Contents/MacOS/PhoneCamCameraExtension"; do
  [[ "$(lipo -archs "$EXECUTABLE")" == arm64 ]] || { echo "Release ZIP is arm64-only, but $EXECUTABLE is not." >&2; exit 1; }
done
for ITEM in "$APP" "$EXT"; do
  SIGNATURE="$(codesign -dv --verbose=4 "$ITEM" 2>&1)"
  [[ "$SIGNATURE" == *'Authority=Developer ID Application:'* ]] || {
    echo "Notarization requires Developer ID Application signing for $ITEM." >&2; exit 1;
  }
done
codesign --verify --deep --strict "$APP"
ARCHIVE="$ROOT/dist/DroidDozeCam-notarization.zip"
RELEASE_ZIP="$ROOT/dist/DroidDozeCam-macos-arm64.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
RESPONSE="$(mktemp "${TMPDIR:-/tmp}/droiddozecam-notary.XXXXXX")"
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/droiddozecam-verify.XXXXXX")"
trap 'rm -f "$RESPONSE"; rm -rf "$VERIFY"' EXIT
xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait --output-format json > "$RESPONSE"
python3 - "$RESPONSE" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization {result.get('status', 'failed')}; submission ID {result.get('id', 'unknown')}. Read its log with xcrun notarytool log.")
print("Notarization accepted:", result["id"])
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$RELEASE_ZIP"
ditto -xk "$RELEASE_ZIP" "$VERIFY"
codesign --verify --deep --strict "$VERIFY/DroidDozeCam.app"
xcrun stapler validate "$VERIFY/DroidDozeCam.app"
spctl --assess --type execute --verbose=2 "$VERIFY/DroidDozeCam.app"
echo "Notarized distribution: $RELEASE_ZIP"
shasum -a 256 "$RELEASE_ZIP"
