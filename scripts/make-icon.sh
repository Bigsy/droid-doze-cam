#!/bin/bash
# Regenerate the macOS ICNS asset from the checked-in PNG master.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo "macOS sips and iconutil are required." >&2; exit 1; }
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/phonecam-icon.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ICONSET="$STAGE/PhoneCam.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/assets/phonecam.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$ROOT/assets/phonecam.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/assets/PhoneCam.icns"
echo "Updated assets/PhoneCam.icns"
