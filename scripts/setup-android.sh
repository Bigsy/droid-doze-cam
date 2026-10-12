#!/bin/bash
set -euo pipefail
VERSION=3.3.4
SHA256=8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e
[[ "$(uname -s)" == Darwin ]] || { echo "This setup script targets macOS." >&2; exit 1; }
[[ ${EUID:-$(id -u)} != 0 ]] || { echo "Run as your normal user, not sudo." >&2; exit 1; }
command -v adb >/dev/null || { echo "Install ADB first: brew install --cask android-platform-tools" >&2; exit 1; }
DIR="$HOME/Library/Application Support/USBWakeCam"
umask 077
mkdir -p "$DIR"
[[ ! -L "$DIR" ]] || { echo "Refusing a symlinked PhoneCam support directory." >&2; exit 1; }
TMP="$(mktemp "$DIR/.scrcpy-download.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 180 \
  "https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-server-v$VERSION" -o "$TMP"
ACTUAL="$(shasum -a 256 "$TMP" | awk '{print $1}')"
[[ "$ACTUAL" == "$SHA256" ]] || { echo "SHA-256 mismatch. Refusing downloaded server." >&2; exit 1; }
chmod 600 "$TMP"
mv -f "$TMP" "$DIR/scrcpy-server-v$VERSION"
echo "Installed official scrcpy-server $VERSION (SHA-256 verified)."
echo "Use a USB data cable. Enable Developer options > USB debugging and approve this Mac on the phone."
echo "Run: usb-wakecam devices; usb-wakecam serve --source android"
