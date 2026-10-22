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
# The app captures with the pinned scrcpy server, from its bundle or from setup-android.sh.
SCRCPY_SERVER_NAME=scrcpy-server-v5.0.1
if [[ ! -f "$APP/Contents/Resources/$SCRCPY_SERVER_NAME" && ! -f "$HOME/Library/Application Support/DroidDozeCam/$SCRCPY_SERVER_NAME" ]]; then
  echo "This build has no scrcpy camera server, so it could not capture. Rebuild it with scripts/build.sh." >&2; exit 1
fi
if [[ ${EUID:-$(id -u)} == 0 ]]; then echo "Run this script as your normal user; it invokes sudo only for installing files." >&2; exit 1; fi
codesign --verify --deep --strict "$APP"
if [[ -e /Applications/DroidDozeCam.app ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/DroidDozeCam.app/Contents/Info.plist)"
  NEW_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  [[ "$EXISTING_ID" == "$NEW_ID" ]] || { echo "An unrelated /Applications/DroidDozeCam.app exists. Refusing to overwrite." >&2; exit 1; }
fi
# Refuse to overwrite an unrelated CLI command.
if [[ -e "$CLI_BIN_DIR/droiddozecam" || -L "$CLI_BIN_DIR/droiddozecam" ]] && ! grep -q 'DroidDozeCam CLI launcher' "$CLI_BIN_DIR/droiddozecam"; then
  echo "An unrelated ${CLI_BIN_DIR}/droiddozecam exists. Move it manually before installation." >&2; exit 1
fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/droiddozecam-install.XXXXXX")"
SERVICE_LABEL=com.hedworth.droiddozecam.service
SERVICE_PLIST="$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"
SERVICE_DOMAIN="gui/$(id -u)"
SERVICE_STOPPED=0
cleanup() {
  status=$?
  trap - EXIT
  if [[ "$SERVICE_STOPPED" == 1 ]]; then
    if ! launchctl bootstrap "$SERVICE_DOMAIN" "$SERVICE_PLIST"; then
      echo "Could not restart the DroidDozeCam login service. Open the app and choose Set Up Camera." >&2
      status=1
    else
      echo "DroidDozeCam login service restarted."
    fi
  fi
  if [[ "$status" == 0 ]]; then
    if open /Applications/DroidDozeCam.app; then
      echo "DroidDozeCam menu bar app opened."
    else
      echo "The app installed, but its menu did not open. Run: open /Applications/DroidDozeCam.app" >&2
    fi
  fi
  rm -rf "$STAGE"
  exit "$status"
}
trap cleanup EXIT
cat > "$STAGE/droiddozecam" <<'LAUNCHER'
#!/bin/sh
# DroidDozeCam CLI launcher — keep execution inside the signed app bundle.
APP=/Applications/DroidDozeCam.app
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist") || exit 1
exec "$APP/Contents/MacOS/$EXECUTABLE" "$@"
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
# The login service has KeepAlive enabled, so stop launchd before replacing its executable.
if [[ -f "$SERVICE_PLIST" ]] && launchctl print "$SERVICE_DOMAIN/$SERVICE_LABEL" >/dev/null 2>&1; then
  launchctl bootout "$SERVICE_DOMAIN" "$SERVICE_PLIST"
  SERVICE_STOPPED=1
fi
# The menu bar app runs the same executable; quit it now and reopen it at the end. Builds before the
# menu handled SIGTERM ignore it, and the menu holds no unsaved state, so fall back to SIGKILL.
MENU_PATTERN='^/Applications/DroidDozeCam[.]app/Contents/MacOS/[^/ ]+( menu)?$'
if pkill -TERM -f "$MENU_PATTERN"; then
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -f "$MENU_PATTERN" >/dev/null; then break; fi
    sleep 0.2
  done
  pkill -KILL -f "$MENU_PATTERN" || true
fi
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if ! pgrep -f '^/Applications/DroidDozeCam[.]app/Contents/MacOS/[^/ ]+( |$)' >/dev/null; then break; fi
  sleep 0.2
done
if pgrep -f '^/Applications/DroidDozeCam[.]app/Contents/MacOS/[^/ ]+( |$)' >/dev/null; then
  echo "Quit running DroidDozeCam commands before installing." >&2
  exit 1
fi
# Replacing a running extension can leave no camera until the next build; macOS unloads it once idle.
for attempt in $(seq 1 60); do
  if ! pgrep -f '/com[.]hedworth[.]usbwakecam[.]camera[.]systemextension/Contents/MacOS/[^/ ]+( |$)' >/dev/null; then break; fi
  sleep 0.5
done
EXTENSION_RUNNING=0
if pgrep -f '/com[.]hedworth[.]usbwakecam[.]camera[.]systemextension/Contents/MacOS/[^/ ]+( |$)' >/dev/null; then
  EXTENSION_RUNNING=1
  echo "The current camera extension is still running; its replacement must wait until macOS unloads it." >&2
fi
# An approved extension can be replaced without a prompt. Do it before the login service restarts,
# because serve and the menu bar app keep the old extension running.
EXTENSION_APPROVED=0
if systemextensionsctl list 2>/dev/null | grep -q "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist").camera .*\[activated enabled\]"; then
  EXTENSION_APPROVED=1
fi
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
# Upgrade the existing login service after the new app verifies, preserving its phone and options.
if [[ -f "$SERVICE_PLIST" ]]; then
  python3 - "$SERVICE_PLIST" <<'PY_SERVICE'
import os
import pathlib
import plistlib
import sys
import tempfile
path = pathlib.Path(sys.argv[1])
with path.open('rb') as handle:
    service = plistlib.load(handle)
arguments = service.get('ProgramArguments', [])
if service.get('Label') != 'com.hedworth.droiddozecam.service' or not arguments:
    raise SystemExit('Unexpected login service; run Set Up Camera to recreate it.')
with open('/Applications/DroidDozeCam.app/Contents/Info.plist', 'rb') as handle:
    executable = plistlib.load(handle)['CFBundleExecutable']
arguments[0] = str(pathlib.Path('/Applications/DroidDozeCam.app/Contents/MacOS') / executable)
fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.droiddozecam-service-')
try:
    with os.fdopen(fd, 'wb') as handle:
        plistlib.dump(service, handle)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY_SERVICE
fi
install_command mkdir -p "$CLI_BIN_DIR"
install_command install -m 755 "$STAGE/droiddozecam" "$CLI_BIN_DIR/droiddozecam"
echo "CLI launcher: $CLI_BIN_DIR/droiddozecam"
# The new app has verified, so remove the previous copy and any left by earlier installers.
# dist/DroidDozeCam.previous.app still holds the previous build.
for OLD_BACKUP in /Applications/.droiddozecam-backup.*; do
  if [[ -d "$OLD_BACKUP" ]]; then install_command rm -rf "$OLD_BACKUP"; fi
done
if [[ -n "$BACKUP" ]]; then echo "Replaced the previous app."; fi
if [[ "$(cat "$ROOT/dist/build-mode.txt")" == --signed ]]; then
  if [[ "$EXTENSION_RUNNING" == 1 ]]; then
    echo "Installed the app. Keep using the current camera extension; activate the new one after the old process exits or after a restart."
  elif [[ "$EXTENSION_APPROVED" == 1 ]]; then
    EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' /Applications/DroidDozeCam.app/Contents/Info.plist)
    "/Applications/DroidDozeCam.app/Contents/MacOS/$EXECUTABLE" install-extension
  else
    echo "Installed. Run as your normal user: droiddozecam install-extension"
  fi
  echo "Then: droiddozecam devices; droiddozecam serve --source android"
  echo "Camera/system-extension approval is interactive. Do not run capture using sudo."
else
  echo "Installed local development build. Use droiddozecam preview, devices, doctor, or probe."
  echo "Optional OBS output: droiddozecam preview --source android --syphon"
  echo "Virtual camera activation requires a properly signed build; run is unavailable until then."
fi
