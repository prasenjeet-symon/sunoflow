#!/bin/bash
# Rebuild SunoFlow and reload the running services in place.
#
# Why this exists: the app is signed with a stable self-signed identity and run
# by a LaunchAgent. After a rebuild the on-disk binary gets a new code hash, and
# `launchctl kickstart -k` on the app job then fails with OS_REASON_CODESIGNING
# ("spawn failed") because launchd cached the OLD hash — even though the binary
# is valid and launches fine directly. The fix is to bootout the app job and
# bootstrap it fresh, with a short settle delay. The Python sidecar job has no
# such issue and restarts with a plain kickstart -k.
set -euo pipefail
cd "$(dirname "$0")"

UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
AGENTS_DIR="$HOME/Library/LaunchAgents"
SIDECAR_LABEL="com.sunoapp.sunoflow.sidecar"
APP_LABEL="com.sunoapp.sunoflow.app"
APP_PLIST="$AGENTS_DIR/$APP_LABEL.plist"
HEALTH_URL="http://127.0.0.1:8765/health"

echo "==> Building app..."
( cd SunoFlowApp && ./build.sh )

if [ ! -f "$APP_PLIST" ]; then
    echo ""
    echo "No LaunchAgent found at $APP_PLIST — you're not using launchd auto-start."
    echo "Relaunch manually with:  ./stop.sh && ./run.sh"
    echo "(or run ./install-autostart.sh once to enable auto-start management.)"
    exit 0
fi

echo "==> Restarting sidecar..."
launchctl kickstart -k "$DOMAIN/$SIDECAR_LABEL" 2>/dev/null || true
echo "    waiting for sidecar health..."
for _ in $(seq 1 180); do
    if curl -s -o /dev/null "$HEALTH_URL"; then echo "    sidecar ready."; break; fi
    sleep 1
done
if ! curl -s -o /dev/null "$HEALTH_URL"; then
    echo "    WARNING: sidecar not healthy — check ~/Library/Logs/SunoFlow/sidecar.log" >&2
fi

echo "==> Reloading app job (refreshes launchd's cached signature)..."
pkill -x SunoFlow 2>/dev/null || true
sleep 1
launchctl bootout "$DOMAIN/$APP_LABEL" 2>/dev/null || true
sleep 3   # bootstrapping too soon after bootout returns "5: Input/output error"

for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "$DOMAIN" "$APP_PLIST" 2>/dev/null; then break; fi
    if [ "$attempt" = "5" ]; then
        echo "ERROR: could not bootstrap $APP_LABEL after retries." >&2
        exit 1
    fi
    sleep 1
done
launchctl enable "$DOMAIN/$APP_LABEL" 2>/dev/null || true
launchctl kickstart "$DOMAIN/$APP_LABEL" 2>/dev/null || true
sleep 2

if pgrep -x SunoFlow >/dev/null; then
    echo "==> Done. SunoFlow relaunched (pid $(pgrep -x SunoFlow | head -1))."
else
    echo "==> WARNING: SunoFlow did not come up. Inspect: launchctl print $DOMAIN/$APP_LABEL" >&2
    exit 1
fi
