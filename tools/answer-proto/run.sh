#!/bin/sh
# PROTOTYPE — build + run the Suno Answer G2 popup harness. Throwaway.
# Compile set: the production sources the answer flow will reuse (recorder,
# hotkey, theme, keychain, injector, screen capture) + the three prototype
# files. Nothing here touches the app or the sidecar.
set -e
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
SRC="$ROOT/SunoFlowApp/Sources/SunoFlow"
OUT="$ROOT/tools/answer-proto/.build"
mkdir -p "$OUT"

# A previous prototype instance holds the hotkey; kill it before rebuilding.
pkill -f SunoAnswerProto 2>/dev/null || true
sleep 0.3

swiftc \
  "$SRC/Theme.swift" \
  "$SRC/Logger.swift" \
  "$SRC/Tone.swift" \
  "$SRC/Preferences.swift" \
  "$SRC/HotkeyManager.swift" \
  "$SRC/AudioDevices.swift" \
  "$SRC/AudioRecorder.swift" \
  "$SRC/ScreenContext.swift" \
  "$SRC/AccountManager.swift" \
  "$SRC/TextInjector.swift" \
  "$ROOT/tools/answer-proto/AnswerPopup.swift" \
  "$ROOT/tools/answer-proto/AnswerFlow.swift" \
  "$ROOT/tools/answer-proto/main.swift" \
  -target arm64-apple-macos13.0 \
  -o "$OUT/SunoAnswerProto"

echo "Built $OUT/SunoAnswerProto — launching (Cmd+Q or Ctrl-C in this terminal quits)."
"$OUT/SunoAnswerProto"