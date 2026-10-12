#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---signed}"
SWIFT_BUILD_FLAGS=()
if [[ "${USB_WAKECAM_DISABLE_SWIFT_SANDBOX:-0}" == 1 ]]; then
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
BUILD_NUMBER="${BUILD_NUMBER:-5}"
if [[ "$MODE" == --signed ]]; then
  : "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Apple Development or Developer ID Application signing identity}"
  : "${HOST_PROFILE:?Set HOST_PROFILE to the host .provisionprofile path}"
  : "${EXT_PROFILE:?Set EXT_PROFILE to the camera extension .provisionprofile path}"
  [[ "$TEAM_ID" != 0000000000 && -f "$HOST_PROFILE" && -f "$EXT_PROFILE" ]] || { echo "A real TEAM_ID and both profiles are required." >&2; exit 1; }
fi
# Staging is private and unique. Never merge unsigned files into an existing signed app.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/phonecam-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/binaries"
HOST_BINARIES=(); EXT_BINARIES=()
for ARCH in $ARCHS; do
  case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1;; esac
  SCRATCH="$ROOT/.build-$ARCH"
  xcrun swift build ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} --package-path "$ROOT" --scratch-path "$SCRATCH" --arch "$ARCH" -c release --product phonecam
  xcrun swift build ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} --package-path "$ROOT" --scratch-path "$SCRATCH" --arch "$ARCH" -c release --product PhoneCamCameraExtension
  BIN="$(xcrun swift build ${SWIFT_BUILD_FLAGS[@]+"${SWIFT_BUILD_FLAGS[@]}"} --package-path "$ROOT" --scratch-path "$SCRATCH" --arch "$ARCH" -c release --show-bin-path)"
  HOST_BINARIES+=("$BIN/phonecam"); EXT_BINARIES+=("$BIN/PhoneCamCameraExtension")
done
if [[ ${#HOST_BINARIES[@]} == 1 ]]; then
  cp "${HOST_BINARIES[0]}" "$STAGE/binaries/phonecam"
  cp "${EXT_BINARIES[0]}" "$STAGE/binaries/PhoneCamCameraExtension"
else
  xcrun lipo -create "${HOST_BINARIES[@]}" -output "$STAGE/binaries/phonecam"
  xcrun lipo -create "${EXT_BINARIES[@]}" -output "$STAGE/binaries/PhoneCamCameraExtension"
fi
python3 "$ROOT/scripts/make-bundles.py" --output "$STAGE/bundle" --binaries "$STAGE/binaries" --team "$TEAM_ID" --bundle-id "$BUNDLE_ID" --build-number "$BUILD_NUMBER"
APP="$STAGE/bundle/USBWakeCam.app"
EXT="$APP/Contents/Library/SystemExtensions/$BUNDLE_ID.camera.systemextension"
if [[ "$MODE" == --signed ]]; then
  if ! security cms -D -i "$HOST_PROFILE" > "$STAGE/host-profile.plist" 2>/dev/null; then
    openssl cms -verify -inform DER -in "$HOST_PROFILE" -noverify -out "$STAGE/host-profile.plist" 2>/dev/null
  fi
  if ! security cms -D -i "$EXT_PROFILE" > "$STAGE/ext-profile.plist" 2>/dev/null; then
    openssl cms -verify -inform DER -in "$EXT_PROFILE" -noverify -out "$STAGE/ext-profile.plist" 2>/dev/null
  fi
  python3 "$ROOT/scripts/check-profile.py" "$STAGE/host-profile.plist" "$STAGE/bundle/Host.entitlements"
  python3 "$ROOT/scripts/check-profile.py" "$STAGE/ext-profile.plist" "$STAGE/bundle/Camera.entitlements"
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
"$APP/Contents/MacOS/phonecam" version
mkdir -p "$ROOT/dist"
if [[ -e "$ROOT/dist/USBWakeCam.app" ]]; then
  if [[ -e "$ROOT/dist/USBWakeCam.previous.app" ]]; then rm -rf "$ROOT/dist/USBWakeCam.previous.app"; fi
  mv "$ROOT/dist/USBWakeCam.app" "$ROOT/dist/USBWakeCam.previous.app"
fi
mv "$APP" "$ROOT/dist/USBWakeCam.app"
cp "$STAGE/bundle/Host.entitlements" "$STAGE/bundle/Camera.entitlements" "$ROOT/dist/"
printf '%s\n' "$MODE" > "$ROOT/dist/build-mode.txt"
echo "Built: $ROOT/dist/USBWakeCam.app ($ARCHS)"
if [[ "$MODE" == --unsigned ]]; then echo "UNSIGNED DEVELOPMENT BUILD: local preview/probe are available; camera-extension activation requires a signed build."
else echo "For release distribution, notarize/staple before installation. See docs/SIGNING.md."; fi
