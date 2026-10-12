#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/DroidDozeCam.app"
CLI_BIN_DIR="${DROIDDOZECAM_BIN_DIR:-}"
if [[ -z "$CLI_BIN_DIR" ]]; then
  if command -v brew >/dev/null 2>&1; then CLI_BIN_DIR="$(brew --prefix)/bin"
  else CLI_BIN_DIR=/usr/local/bin; fi
fi
[[ "$CLI_BIN_DIR" == /* ]] || { echo "DROIDDOZECAM_BIN_DIR must be an absolute path." >&2; exit 64; }
[[ "$(uname -s)" == Darwin ]] || { echo "macOS is required." >&2; exit 1; }
[[ -d "$APP" ]] || { echo "Build first: scripts/build.sh --signed" >&2; exit 1; }
if [[ ${EUID:-$(id -u)} == 0 ]]; then echo "Run this script as your normal user; it invokes sudo only for installing files." >&2; exit 1; fi
codesign --verify --deep --strict "$APP"
if [[ -e /Applications/DroidDozeCam.app ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/DroidDozeCam.app/Contents/Info.plist)"
  NEW_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  [[ "$EXISTING_ID" == "$NEW_ID" ]] || { echo "An unrelated /Applications/DroidDozeCam.app exists. Refusing to overwrite." >&2; exit 1; }
fi
if pgrep -f '^/Applications/DroidDozeCam.app/Contents/MacOS/phonecam( |$)' >/dev/null; then
  echo "Stop all running DroidDozeCam commands before installing." >&2; exit 1
fi
# Refuse to overwrite an unrelated CLI command.
if [[ -e "$CLI_BIN_DIR/droiddozecam" || -L "$CLI_BIN_DIR/droiddozecam" ]] && ! grep -q 'DroidDozeCam CLI launcher' "$CLI_BIN_DIR/droiddozecam"; then
  echo "An unrelated ${CLI_BIN_DIR}/droiddozecam exists. Move it manually before installation." >&2; exit 1
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/phonecam-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/droiddozecam" <<'LAUNCHER'
#!/bin/sh
# DroidDozeCam CLI launcher — keep execution inside the signed app bundle.
exec /Applications/DroidDozeCam.app/Contents/MacOS/phonecam "$@"
LAUNCHER
# Use the current account when the installation locations are already writable.
NEEDS_SUDO=0
if [[ ! -w /Applications || ! -d "$CLI_BIN_DIR" || ! -w "$CLI_BIN_DIR" ]] ||
   [[ -d /Applications/DroidDozeCam.app && ! -w /Applications/DroidDozeCam.app ]]; then
  sudo -v
  NEEDS_SUDO=1
fi
install_command() {
  if [[ "$NEEDS_SUDO" == 1 ]]; then sudo "$@"; else "$@"; fi
}
# Preserve the previous app until the replacement has been verified.
BACKUP=""
if [[ -d /Applications/DroidDozeCam.app ]]; then
  BACKUP="$(install_command mktemp -d /Applications/.droiddozecam-backup.XXXXXX)"
  install_command mv /Applications/DroidDozeCam.app "$BACKUP/DroidDozeCam.app"
fi
if ! install_command /usr/bin/ditto "$APP" /Applications/DroidDozeCam.app ||
   ! codesign --verify --deep --strict /Applications/DroidDozeCam.app; then
  install_command rm -rf /Applications/DroidDozeCam.app
  if [[ -n "$BACKUP" ]]; then install_command mv "$BACKUP/DroidDozeCam.app" /Applications/DroidDozeCam.app; fi
  echo "Installation failed; the previous app was restored if one existed." >&2
  exit 1
fi
install_command mkdir -p "$CLI_BIN_DIR"
install_command install -m 755 "$STAGE/droiddozecam" "$CLI_BIN_DIR/droiddozecam"
echo "CLI launcher: $CLI_BIN_DIR/droiddozecam"
if [[ -n "$BACKUP" ]]; then echo "Previous app retained: $BACKUP/DroidDozeCam.app"; fi
if [[ "$(cat "$ROOT/dist/build-mode.txt")" == --signed ]]; then
  echo "Installed. Run as your normal user: droiddozecam install-extension"
  echo "Then: droiddozecam devices; droiddozecam serve --source android"
  echo "Camera/system-extension approval is interactive. Do not run capture using sudo."
else
  echo "Installed local development build. Use droiddozecam preview, devices, doctor, or probe."
  echo "Optional OBS output: droiddozecam preview --source android --syphon"
  echo "Virtual camera activation requires a properly signed build; run is unavailable until then."
fi
