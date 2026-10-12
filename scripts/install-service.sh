#!/bin/bash
set -euo pipefail

SERIAL="${1:?Usage: scripts/install-service.sh USB_SERIAL}"
[[ "$SERIAL" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "Invalid USB serial." >&2; exit 64; }
APP=/Applications/DroidDozeCam.app
CLI="$APP/Contents/MacOS/phonecam"
[[ -x "$CLI" ]] || { echo "Install the signed DroidDozeCam.app in /Applications first." >&2; exit 1; }
codesign --verify --deep --strict "$APP"

LABEL=com.hedworth.droiddozecam.service
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
python3 - "$PLIST" "$CLI" "$SERIAL" <<'PY'
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
value = {
    "Label": "com.hedworth.droiddozecam.service",
    "ProgramArguments": [sys.argv[2], "serve", "--source", "android", "--serial", sys.argv[3]],
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": str(pathlib.Path.home() / "Library/Logs/DroidDozeCam.log"),
    "StandardErrorPath": str(pathlib.Path.home() / "Library/Logs/DroidDozeCam.log"),
}
with path.open("wb") as handle:
    plistlib.dump(value, handle)
PY
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed login service for $SERIAL. It waits until a Mac app opens DroidDozeCam."
