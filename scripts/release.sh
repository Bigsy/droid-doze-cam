#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${TEAM_ID:?Set your Apple Developer Team ID}"
: "${SIGN_IDENTITY:?Set a Developer ID Application signing identity}"
: "${HOST_PROFILE:?Set the Developer ID host provisioning profile path}"
: "${EXT_PROFILE:?Set the Developer ID camera extension provisioning profile path}"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  : "${NOTARY_APPLE_ID:?Set a notarytool keychain profile or NOTARY_APPLE_ID}"
  [[ -n "${NOTARY_PASSWORD:-}" ]] || { echo "Missing CI notarization credential." >&2; exit 1; }
fi
: "${BUILD_NUMBER:?Set a new, increasing camera extension build number}"
[[ "$SIGN_IDENTITY" == 'Developer ID Application:'* ]] || {
  echo "Public releases require a Developer ID Application identity, not Apple Development." >&2; exit 1;
}
security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY" || {
  echo "The Developer ID Application identity is not installed in this Mac's keychain." >&2; exit 1;
}
[[ -f "$HOST_PROFILE" && -f "$EXT_PROFILE" ]] || {
  echo "Both Developer ID provisioning profiles must exist." >&2; exit 1;
}

# scrcpy is Apache-2.0. Bundle its pinned official server and license so a
# downloaded app does not need to fetch a second executable on first run.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/droiddozecam-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
SCRCPY_SERVER="$STAGE/scrcpy-server-v3.3.4"
SCRCPY_LICENSE="$STAGE/scrcpy-LICENSE.txt"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
  https://github.com/Genymobile/scrcpy/releases/download/v3.3.4/scrcpy-server-v3.3.4 -o "$SCRCPY_SERVER"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
  https://raw.githubusercontent.com/Genymobile/scrcpy/v3.3.4/LICENSE -o "$SCRCPY_LICENSE"
echo '8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e  '"$SCRCPY_SERVER" | shasum -a 256 -c -
echo '5e6597827749877cca06765747bf29ed9205ed5021c6aec1ad42373711bcda05  '"$SCRCPY_LICENSE" | shasum -a 256 -c -

export ARCHS=arm64 RELEASE_BUILD=1 SCRCPY_SERVER SCRCPY_LICENSE
"$ROOT/scripts/build.sh" --signed
"$ROOT/scripts/notarize.sh"

echo "Upload dist/DroidDozeCam-macos-arm64.zip as a GitHub Release asset after testing it on another Apple Silicon Mac."
