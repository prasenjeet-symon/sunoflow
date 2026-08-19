#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

PID_FILE="sidecar.pid"

echo "Quitting SunoFlow.app..."
osascript -e 'tell application "SunoFlow" to quit' 2>/dev/null || pkill -x SunoFlow 2>/dev/null || true

if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping sidecar (pid $PID)..."
        kill "$PID"
    fi
    rm -f "$PID_FILE"
else
    echo "No sidecar.pid found; nothing to stop."
fi
