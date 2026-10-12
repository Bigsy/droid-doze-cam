#!/bin/bash
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.hedworth.usbwakecam.service.plist"
if [[ -f "$PLIST" ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm "$PLIST"
fi
echo "USB WakeCam login service removed."
