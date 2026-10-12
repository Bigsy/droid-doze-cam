#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/USBWakeCam.app"
CLI_BIN_DIR="${USB_WAKECAM_BIN_DIR:-}"
if [[ -z "$CLI_BIN_DIR" ]]; then
  if command -v brew >/dev/null 2>&1; then CLI_BIN_DIR="$(brew --prefix)/bin"
  else CLI_BIN_DIR=/usr/local/bin; fi
fi
[[ "$CLI_BIN_DIR" == /* ]] || { echo "USB_WAKECAM_BIN_DIR must be an absolute path." >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || { echo "macOS is required." >&2; exit 1; }
[[ -d "$APP" ]] || { echo "Build first: scripts/build.sh --signed" >&2; exit 1; }
if [[ ${EUID:-$(id -u)} == 0 ]]; then echo "Run this script as your normal user; it invokes sudo only for installing files." >&2; exit 1; fi
codesign --verify --deep --strict "$APP"
if [[ -e /Applications/USBWakeCam.app ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/USBWakeCam.app/Contents/Info.plist)"
  NEW_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  [[ "$EXISTING_ID" == "$NEW_ID" ]] || { echo "An unrelated /Applications/USBWakeCam.app exists. Refusing to overwrite." >&2; exit 1; }
fi
if pgrep -f '^/Applications/USBWakeCam.app/Contents/MacOS/phonecam( |$)' >/dev/null; then
  echo "Stop all running USB WakeCam commands before installing." >&2; exit 1
fi
# Refuse to overwrite an unrelated CLI command.
if [[ -e "$CLI_BIN_DIR/usb-wakecam" || -L "$CLI_BIN_DIR/usb-wakecam" ]] && ! grep -q 'USB WakeCam CLI launcher' "$CLI_BIN_DIR/usb-wakecam"; then
  echo "An unrelated ${CLI_BIN_DIR}/usb-wakecam exists. Move it manually before installation." >&2; exit 1
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/phonecam-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/usb-wakecam" <<'LAUNCHER'
#!/bin/sh
# USB WakeCam CLI launcher — keep execution inside the signed app bundle.
exec /Applications/USBWakeCam.app/Contents/MacOS/phonecam "$@"
LAUNCHER
# Use the current account when the installation locations are already writable.
NEEDS_SUDO=0
if [[ ! -w /Applications || ! -d "$CLI_BIN_DIR" || ! -w "$CLI_BIN_DIR" ]] ||
   [[ -d /Applications/USBWakeCam.app && ! -w /Applications/USBWakeCam.app ]]; then
  sudo -v
  NEEDS_SUDO=1
fi
install_command() {
  if [[ "$NEEDS_SUDO" == 1 ]]; then sudo "$@"; else "$@"; fi
}
# Preserve the previous app until the replacement has been verified.
BACKUP=""
if [[ -d /Applications/USBWakeCam.app ]]; then
  BACKUP="$(install_command mktemp -d /Applications/.usb-wakecam-backup.XXXXXX)"
  install_command mv /Applications/USBWakeCam.app "$BACKUP/USBWakeCam.app"
fi
if ! install_command /usr/bin/ditto "$APP" /Applications/USBWakeCam.app ||
   ! codesign --verify --deep --strict /Applications/USBWakeCam.app; then
  install_command rm -rf /Applications/USBWakeCam.app
  if [[ -n "$BACKUP" ]]; then install_command mv "$BACKUP/USBWakeCam.app" /Applications/USBWakeCam.app; fi
  echo "Installation failed; the previous app was restored if one existed." >&2
  exit 1
fi
install_command mkdir -p "$CLI_BIN_DIR"
install_command install -m 755 "$STAGE/usb-wakecam" "$CLI_BIN_DIR/usb-wakecam"
echo "CLI launcher: $CLI_BIN_DIR/usb-wakecam"
if [[ -n "$BACKUP" ]]; then echo "Previous app retained: $BACKUP/USBWakeCam.app"; fi
if [[ "$(cat "$ROOT/dist/build-mode.txt")" == --signed ]]; then
  echo "Installed. Run as your normal user: usb-wakecam install-extension"
  echo "Then: usb-wakecam devices; usb-wakecam serve --source android"
  echo "Camera/system-extension approval is interactive. Do not run capture using sudo."
else
  echo "Installed local development build. Use usb-wakecam preview, devices, doctor, or probe."
  echo "Optional OBS output: usb-wakecam preview --source android --syphon"
  echo "Virtual camera activation requires a properly signed build; run is unavailable until then."
fi
