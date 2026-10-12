#!/bin/bash
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.hedworth.droiddozecam.service.plist"
if [[ -f "$PLIST" ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm "$PLIST"
fi
echo "DroidDozeCam login service removed."
