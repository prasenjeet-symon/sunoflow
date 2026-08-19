#!/bin/sh
# com.sunoflow.ollama-env — ensure Ollama binds to 0.0.0.0:11434 at login
# so the cleanup-gateway Docker container can reach it via host.ollama.
#
# Problem: `launchctl setenv OLLAMA_HOST` is per GUI session and is LOST on
# reboot. After a reboot Ollama's login item launches with the default
# OLLAMA_HOST=127.0.0.1:11434, so the gateway container cannot connect and
# /cleanup silently falls back to returning raw (un-cleaned) text.
#
# This LaunchAgent runs once at login, publishes OLLAMA_HOST into the global
# launchd environment, and restarts Ollama if it already came up bound to
# 127.0.0.1 only. If Ollama comes up after this script (or is already correct),
# nothing is restarted.

LOG="$HOME/Library/Logs/SunoFlow/ollama-env.log"
TARGET="0.0.0.0:11434"
OLLAMA_APP="/Applications/Ollama.app"
MAX_WAIT=30

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

log "=== ollama-env start ==="

# 1. Publish OLLAMA_HOST into the global launchd environment for this GUI
#    session, so any process launchd starts afterwards (incl. Ollama) inherits it.
if launchctl setenv OLLAMA_HOST "$TARGET"; then
    log "setenv OLLAMA_HOST=$TARGET ok"
else
    log "setenv FAILED — continuing anyway"
fi

# 2. Detect ollama serve's bind. `*:11434` = all interfaces (correct);
#    `127.0.0.1:11434` = loopback only (wrong, needs restart).
correct_bind() { lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -q "\*:11434"; }
wrong_bind()   { lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | grep -q "127.0.0.1:11434"; }

# Give Ollama's login item time to come up, then decide.
i=0
while [ "$i" -lt "$MAX_WAIT" ]; do
    if correct_bind; then log "already bound to *:11434 — nothing to do"; exit 0; fi
    if wrong_bind;   then log "bound to 127.0.0.1 only — will restart Ollama"; break; fi
    i=$((i + 1)); sleep 1
done

# 3. Restart Ollama so it re-reads OLLAMA_HOST and rebinds to all interfaces.
if ! correct_bind; then
    log "restarting Ollama to pick up OLLAMA_HOST=$TARGET"
    pkill -f "Ollama.app/Contents/Resources/ollama serve" 2>/dev/null || true
    pkill -f "Ollama.app/Contents/MacOS/Ollama" 2>/dev/null || true
    sleep 2
    open -a "$OLLAMA_APP"
    j=0
    while [ "$j" -lt "$MAX_WAIT" ]; do
        if correct_bind; then log "rebound to *:11434 ok"; exit 0; fi
        j=$((j + 1)); sleep 1
    done
    log "WARNING: ollama did not rebind to *:11434 after restart — check manually"
fi

log "=== ollama-env end ==="