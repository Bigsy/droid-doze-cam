#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---signed}"
SWIFT_BUILD_FLAGS=()
if [[ "${DROIDDOZECAM_DISABLE_SWIFT_SANDBOX:-0}" == 1 ]]; then
  SWIFT_BUILD_FLAGS+=(--disable-sandbox)
  mkdir -p "$ROOT/.module-cache"
  export CLANG_MODULE_CACHE_PATH="$ROOT/.module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.module-cache"
fi
if [[ "$MODE" != --signed && "$MODE" != --unsigned ]]; then echo "Usage: $0 [--signed|--unsigned]" >&2; exit 64; fi
if [[ "$(uname -s)" != Darwin ]]; then echo "macOS + Xcode 15 or later are required. Linux can run the core tests only." >&2; exit 1; fi
command -v python3 >/dev/null || { echo "python3 is required (included with Xcode command-line tools)." >&2; exit 1; }
xcrun --find swift >/dev/null
TEAM_ID="${TEAM_ID:-0000000000}"
BUNDLE_ID="${BUNDLE_ID:-com.hedworth.usbwakecam}"
ARCHS="${ARCHS:-$(uname -m)}"
# scripts/test.sh builds elsewhere so it never replaces the signed app that make install uses.
DIST="${DIST_DIR:-$ROOT/dist}"
# macOS only replaces an installed camera extension with a new build number, so default to a timestamp.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
if [[ "$MODE" == --signed ]]; then
  : "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Apple Development or Developer ID Application signing identity}"
  : "${HOST_PROFILE:?Set HOST_PROFILE to the host .provisionprofile path}"
  : "${EXT_PROFILE:?Set EXT_PROFILE to the camera extension .provisionprofile path}"
  [[ "$TEAM_ID" != 0000000000 && -f "$HOST_PROFILE" && -f "$EXT_PROFILE" ]] || { echo "A real TEAM_ID and both profiles are required." >&2; exit 1; }
  if [[ "${RELEASE_BUILD:-0}" == 1 && "$SIGN_IDENTITY" != 'Developer ID Application:'* ]]; then
    echo "Release builds require a Developer ID Application signing identity." >&2; exit 1
  fi
fi
# Android capture needs the pinned scrcpy server inside the app; without it the app cannot capture
# unless setup-android.sh has run. Fetch the official server and its Apache-2.0 license once into
# .cache before the long compile. make-bundles.py checks both against their pinned SHA-256.
SCRCPY_VERSION=5.0.1
if [[ -n "${SCRCPY_SERVER:-}" || -n "${SCRCPY_LICENSE:-}" ]]; then
  : "${SCRCPY_SERVER:?Set both SCRCPY_SERVER and SCRCPY_LICENSE}"
  : "${SCRCPY_LICENSE:?Set both SCRCPY_SERVER and SCRCPY_LICENSE}"
else
  SCRCPY_CACHE="$ROOT/.cache/scrcpy-v$SCRCPY_VERSION"
  SCRCPY_SERVER="$SCRCPY_CACHE/scrcpy-server-v$SCRCPY_VERSION"
  SCRCPY_LICENSE="$SCRCPY_CACHE/LICENSE"
  mkdir -p "$SCRCPY_CACHE"
  fetch_scrcpy() {
    if [[ -s "$2" ]]; then return; fi
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 "$1" -o "$2.part" ||
      { echo "Could not download $1. Set SCRCPY_SERVER and SCRCPY_LICENSE to local copies." >&2; exit 1; }
    mv "$2.part" "$2"
  }
  fetch_scrcpy "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY_VERSION/scrcpy-server-v$SCRCPY_VERSION" "$SCRCPY_SERVER"
  fetch_scrcpy "https://raw.githubusercontent.com/Genymobile/scrcpy/v$SCRCPY_VERSION/LICENSE" "$SCRCPY_LICENSE"
fi
# Staging is private and unique. Never merge unsigned files into an existing signed app.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/droiddozecam-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/binaries"
HOST_BINARIES=(); EXT_BINARIES=()
for ARCH in $ARCHS; do
  case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1;; esac
  SCRATCH="$ROOT/.build-$ARCH"
  xcrun swift build ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} --package-path "$ROOT" --scratch-path "$SCRATCH" --arch "$ARCH" -c release --product droiddozecam
  xcrun swift build ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} --package-path "$ROOT" --scratch-path "$SCRATCH" --arch "$ARCH" -c release --product DroidDozeCamCameraExtension
  BIN="$(xcrun swift build ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} --package-path "$ROOT" --scratch-path "$SCRATCH" --arch "$ARCH" -c release --show-bin-path)"
  HOST_BINARIES+=("$BIN/droiddozecam"); EXT_BINARIES+=("$BIN/DroidDozeCamCameraExtension")
done
if [[ ${#HOST_BINARIES[@]} == 1 ]]; then
  cp "${HOST_BINARIES[0]}" "$STAGE/binaries/droiddozecam"
  cp "${EXT_BINARIES[0]}" "$STAGE/binaries/DroidDozeCamCameraExtension"
else
  xcrun lipo -create "${HOST_BINARIES[@]}" -output "$STAGE/binaries/droiddozecam"
  xcrun lipo -create "${EXT_BINARIES[@]}" -output "$STAGE/binaries/DroidDozeCamCameraExtension"
fi
python3 "$ROOT/scripts/make-bundles.py" --output "$STAGE/bundle" --binaries "$STAGE/binaries" --team "$TEAM_ID" --bundle-id "$BUNDLE_ID" --build-number "$BUILD_NUMBER" \
  --scrcpy-server "$SCRCPY_SERVER" --scrcpy-license "$SCRCPY_LICENSE"
APP="$STAGE/bundle/DroidDozeCam.app"
EXT="$APP/Contents/Library/SystemExtensions/$BUNDLE_ID.camera.systemextension"
if [[ "$MODE" == --signed ]]; then
  if ! security cms -D -i "$HOST_PROFILE" > "$STAGE/host-profile.plist" 2>/dev/null; then
    openssl cms -verify -inform DER -in "$HOST_PROFILE" -noverify -out "$STAGE/host-profile.plist" 2>/dev/null
  fi
  if ! security cms -D -i "$EXT_PROFILE" > "$STAGE/ext-profile.plist" 2>/dev/null; then
    openssl cms -verify -inform DER -in "$EXT_PROFILE" -noverify -out "$STAGE/ext-profile.plist" 2>/dev/null
  fi
  PROFILE_ARGS=()
  if [[ "${RELEASE_BUILD:-0}" == 1 ]]; then PROFILE_ARGS+=(--distribution); fi
  python3 "$ROOT/scripts/check-profile.py" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} "$STAGE/host-profile.plist" "$STAGE/bundle/Host.entitlements"
  python3 "$ROOT/scripts/check-profile.py" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} "$STAGE/ext-profile.plist" "$STAGE/bundle/Camera.entitlements"
  cp "$HOST_PROFILE" "$APP/Contents/embedded.provisionprofile"
  cp "$EXT_PROFILE" "$EXT/Contents/embedded.provisionprofile"
  TIMESTAMP_FLAG=--timestamp
  if [[ "$SIGN_IDENTITY" == 'Apple Development:'* ]]; then TIMESTAMP_FLAG=--timestamp=none; fi
  codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" --entitlements "$STAGE/bundle/Camera.entitlements" "$EXT"
  codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" --entitlements "$STAGE/bundle/Host.entitlements" "$APP"
else
  # Ad-hoc signing permits local capture and preview, but cannot activate the camera system extension.
  codesign --force --sign - "$EXT"
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist"
"$APP/Contents/MacOS/droiddozecam" version
mkdir -p "$DIST"
if [[ -e "$DIST/DroidDozeCam.app" ]]; then
  if [[ -e "$DIST/DroidDozeCam.previous.app" ]]; then rm -rf "$DIST/DroidDozeCam.previous.app"; fi
  mv "$DIST/DroidDozeCam.app" "$DIST/DroidDozeCam.previous.app"
fi
mv "$APP" "$DIST/DroidDozeCam.app"
cp "$STAGE/bundle/Host.entitlements" "$STAGE/bundle/Camera.entitlements" "$DIST/"
printf '%s\n' "$MODE" > "$DIST/build-mode.txt"
echo "Built: $DIST/DroidDozeCam.app ($ARCHS)"
if [[ "$MODE" == --unsigned ]]; then echo "UNSIGNED DEVELOPMENT BUILD: local preview/probe are available; camera-extension activation requires a signed build."
else echo "For release distribution, notarize/staple before installation. See docs/RELEASE.md."; fi
