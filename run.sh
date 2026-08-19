#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SIDECAR_DIR="sidecar"
APP_BUNDLE="SunoFlowApp/SunoFlow.app"
HEALTH_URL="http://127.0.0.1:8765/health"
PID_FILE="sidecar.pid"
LOG_FILE="sidecar.log"

if curl -s -o /dev/null "$HEALTH_URL"; then
    echo "Sidecar already running."
else
    echo "Starting sidecar (loading Parakeet model, first run can take a minute)..."
    (
        cd "$SIDECAR_DIR"
        source .venv/bin/activate
        nohup python server.py > "../$LOG_FILE" 2>&1 &
        echo $! > "../$PID_FILE"
    )

    echo "Waiting for sidecar to become healthy..."
    for _ in $(seq 1 180); do
        if curl -s -o /dev/null "$HEALTH_URL"; then
            echo "Sidecar is ready."
            break
        fi
        sleep 1
    done

    if ! curl -s -o /dev/null "$HEALTH_URL"; then
        echo "Sidecar did not become healthy in time. Check $LOG_FILE for details." >&2
        exit 1
    fi
fi

if [ ! -d "$APP_BUNDLE" ]; then
    echo "$APP_BUNDLE not found, building it..."
    (cd SunoFlowApp && ./build.sh)
fi

echo "Launching SunoFlow.app..."
open "$APP_BUNDLE"

echo ""
echo "SunoFlow is running. Look for the mic icon in the menu bar."
echo "Press Option+Space to start/stop dictation."
echo "Run ./stop.sh to shut everything down."
