#!/bin/bash
# Removes the SunoFlow auto-start LaunchAgents (sidecar + app).
set -euo pipefail

AGENTS_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
SIDECAR_LABEL="com.sunoapp.sunoflow.sidecar"
APP_LABEL="com.sunoapp.sunoflow.app"

for label in "$SIDECAR_LABEL" "$APP_LABEL"; do
    echo "Unloading $label..."
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    rm -f "$AGENTS_DIR/$label.plist"
done

pkill -x SunoFlow 2>/dev/null || true

echo "Auto-start removed. SunoFlow will no longer start at login."
echo "You can still run it manually with ./run.sh"
