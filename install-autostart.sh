#!/bin/bash
# Installs macOS LaunchAgents so SunoFlow's sidecar and app start automatically
# at login (and the sidecar stays alive). Idempotent — safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd -P)"

VENV_PY="$PROJECT_DIR/sidecar/.venv/bin/python"
SERVER_PY="$PROJECT_DIR/sidecar/server.py"
DEV_APP_BIN="$PROJECT_DIR/SunoFlowApp/SunoFlow.app/Contents/MacOS/SunoFlow"
INSTALLED_APP_BIN="/Applications/SunoFlow.app/Contents/MacOS/SunoFlow"
# Prefer the installed /Applications copy when present (it's what the user and
# launchd should run). Fall back to the dev build under the repo for first-run
# / CI use where the app hasn't been installed yet.
if [ -e "$INSTALLED_APP_BIN" ]; then
    APP_BIN="$INSTALLED_APP_BIN"
else
    APP_BIN="$DEV_APP_BIN"
fi
AGENTS_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

# IMPORTANT: logs must live OUTSIDE ~/Downloads. macOS TCC-protects Downloads,
# so launchd cannot open a StandardOutPath there and the whole job fails to spawn
# with EX_CONFIG (78) before the program even runs. ~/Library/Logs is fine.
LOG_DIR="$HOME/Library/Logs/SunoFlow"
mkdir -p "$LOG_DIR"

SIDECAR_LABEL="com.sunoapp.sunoflow.sidecar"
APP_LABEL="com.sunoapp.sunoflow.app"
SIDECAR_PLIST="$AGENTS_DIR/$SIDECAR_LABEL.plist"
APP_PLIST="$AGENTS_DIR/$APP_LABEL.plist"

for f in "$VENV_PY" "$SERVER_PY" "$APP_BIN"; do
    if [ ! -e "$f" ]; then
        echo "ERROR: missing $f." >&2
        if [ "$f" = "$APP_BIN" ]; then
            echo "  Build the app (cd SunoFlowApp && ./build.sh) and optionally copy it to /Applications." >&2
        else
            echo "  Build the app (SunoFlowApp/build.sh) and set up the venv first." >&2
        fi
        exit 1
    fi
done

echo "App binary: $APP_BIN"

mkdir -p "$AGENTS_DIR"

echo "Stopping any manually-started instances..."
if [ -f "$PROJECT_DIR/sidecar.pid" ]; then
    kill "$(cat "$PROJECT_DIR/sidecar.pid")" 2>/dev/null || true
    rm -f "$PROJECT_DIR/sidecar.pid"
fi
pkill -f "$SERVER_PY" 2>/dev/null || true
pkill -x SunoFlow 2>/dev/null || true
sleep 1

echo "Writing $SIDECAR_PLIST"
cat > "$SIDECAR_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SIDECAR_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV_PY</string>
        <string>$SERVER_PY</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR/sidecar</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- /opt/homebrew/bin is required so parakeet-mlx can find ffmpeg. -->
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/sidecar.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/sidecar.log</string>
</dict>
</plist>
PLIST

echo "Writing $APP_PLIST"
cat > "$APP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$APP_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN</string>
    </array>
    <!-- Start at login, but let the user quit it (no KeepAlive). -->
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/app.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/app.log</string>
</dict>
</plist>
PLIST

echo "Loading LaunchAgents..."
# Unload both first, then let launchd settle — bootstrapping immediately after a
# bootout transiently fails with "5: Input/output error".
for label in "$SIDECAR_LABEL" "$APP_LABEL"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
done
sleep 2
for label in "$SIDECAR_LABEL" "$APP_LABEL"; do
    plist="$AGENTS_DIR/$label.plist"
    launchctl enable "$DOMAIN/$label" 2>/dev/null || true
    for attempt in 1 2 3 4 5; do
        if launchctl bootstrap "$DOMAIN" "$plist" 2>/dev/null; then
            break
        fi
        if [ "$attempt" = "5" ]; then
            echo "ERROR: could not bootstrap $label after retries." >&2
        fi
        sleep 1
    done
done

# Start them now (kickstart the sidecar so we can wait for health).
launchctl kickstart -k "$DOMAIN/$SIDECAR_LABEL"

echo "Waiting for sidecar to become healthy..."
for _ in $(seq 1 180); do
    if curl -s -o /dev/null "http://127.0.0.1:8765/health"; then
        echo "Sidecar is ready."
        break
    fi
    sleep 1
done

launchctl kickstart "$DOMAIN/$APP_LABEL" 2>/dev/null || true

echo ""
echo "Done. SunoFlow will now start automatically every time you log in."
echo "To remove auto-start later, run ./uninstall-autostart.sh"
