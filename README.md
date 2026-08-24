# SunoFlow

A local, Wispr Flow / Superwhisper-style dictation app for macOS: press a hotkey,
speak, and the transcribed (and cleaned-up) text is typed into whatever app you're
focused on. Speech-to-text runs entirely on-device — no cloud STT, your voice never
leaves your Mac.

- **Speech-to-text (on-device)**: NVIDIA Parakeet TDT 0.6B, run via
  [`parakeet-mlx`](https://github.com/senstella/parakeet-mlx) on Apple's MLX
  framework (Apple Silicon GPU/Neural Engine, no CUDA needed). The model is
  **downloaded on demand** from inside the app on first run — it is not bundled,
  so the installer stays small.
- **Cleanup pass**: an LLM fixes grammar/punctuation and strips filler words from
  the raw transcript. By default this uses a local Ollama model; the cleanup backend
  is configurable (see *Settings → AI Cleanup*).
- **App**: a native Swift menu-bar app (no Dock icon) that owns the global hotkey,
  mic capture, and text insertion.

> **Apple Silicon only.** Parakeet-MLX depends on Apple's MLX framework, which runs
> exclusively on M-series Macs. Intel Macs are not supported.

## Architecture

```
┌─────────────────────────┐   HTTP (localhost:8765)   ┌───────────────────────────┐
│  SunoFlow.app  (Swift)  │ ────────────────────────► │  sidecar/server.py        │
│  - global hotkey        │                            │  (FastAPI, on-device)     │
│  - mic capture → WAV    │ ◄──────────────────────── │  - Parakeet TDT 0.6B v2   │
│  - paste text at cursor │   {raw, cleaned}           │  - Ollama llama3.2:3b     │
└─────────────────────────┘                            └───────────────────────────┘
```

The Swift app and the Python sidecar are separate processes talking over a local
HTTP port. This keeps native macOS integration (hotkeys, Accessibility, pasteboard)
in Swift, and ML inference (MLX, Ollama) in Python, without needing to embed a
Python runtime inside the app bundle.

## One-time setup

1. **Homebrew Python 3.12** — needed because MLX/parakeet-mlx require Python 3.10+,
   newer than macOS's bundled Python 3.9.
   ```bash
   brew install python@3.12
   ```

2. **Sidecar virtualenv**:
   ```bash
   cd sidecar
   /opt/homebrew/bin/python3.12 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```

3. **(Optional) Ollama** — only needed if you want the cleanup pass to run locally.
   If Ollama isn't installed/running, transcription still works — it just returns the
   raw transcript without LLM cleanup. To enable local cleanup:
   ```bash
   ollama pull llama3.2:3b
   ```

4. **Build the app**:
   ```bash
   cd SunoFlowApp
   ./setup-signing.sh   # one-time: creates the stable self-signed cert
   ./build.sh
   ```

5. **Download the speech model** — the Parakeet model (~2.5 GB) is **not bundled**.
   After launching the app, open **Settings → Model** and click **Download**. The
   model streams from Hugging Face into
   `~/Library/Application Support/SunoFlow/model/` and loads automatically when
   complete — no restart needed. You can watch live progress in the same tab.

   > Want to pre-place the model or point the sidecar at a different location? Set
   > the `SUNOFLOW_MODEL_DIR` environment variable before starting the sidecar.

## Running

From the project root:

```bash
./run.sh
```

This starts the sidecar (first launch loads the Parakeet model — can take up to a
minute), waits for it to become healthy, then launches `SunoFlow.app`.

```bash
./stop.sh
```

Quits the app and stops the sidecar.

## Permissions you'll need to grant (macOS will prompt on first use)

- **Microphone** — required to record your voice.
- **Accessibility** — required so the app can simulate Cmd+V to insert text into
  the focused app. Grant it under **System Settings → Privacy & Security →
  Accessibility** (look for "SunoFlow"). If you rebuild the app and it stops
  working, you may need to remove and re-add it in that list.

## Using it

1. Click into any text field in any app.
2. Press **Option+Space** — a small paper pill settles in at the top-center of
   the screen with a violet waveform, and the menu bar icon turns into a filled
   mic. It's the same paper, hairline and accent as the dashboard: everything
   SunoFlow floats over your screen is drawn from one set of tokens.
3. Speak — the waveform reacts to your voice (it swells in the center and tapers
   at the edges).
4. Press **Option+Space** again to stop — the pill's waveform shifts to a
   gentle "thinking" animation while it transcribes and cleans up, then the
   result is pasted at your cursor automatically (your existing clipboard
   contents are restored right after) and the pill fades away.

The menu bar dropdown also shows live status and your last transcript.

### When there's nowhere to paste

Pasting only works if something is focused to receive it. If you dictate while
reading a web page, or after clicking onto the desktop, a simulated Cmd+V goes
nowhere and the transcript is lost — which looks exactly like dictation failing.

So before inserting, SunoFlow asks the Accessibility API what has focus. When
there is no editable target it doesn't paste at all: a card rises at the
bottom-center of the screen with the whole transcript and a **Copy text** button,
so the words are one click from your clipboard. The same card appears when
Accessibility isn't granted, since without it the app can't press Cmd+V at all.

It's drawn in the dashboard's design language rather than as a system HUD — the
same paper, ink, hairline rules and single filled action, pinned to the light
appearance the palette was drawn for. The hairline that closes the transcript
doubles as the clock: it drains as the card's time runs out, longer transcripts
get longer on screen, and the countdown pauses while your pointer is over it.
Turn the whole behaviour off in Settings → General → "Nowhere to paste" if you'd
rather it always pasted and took its chances.

Menu bar icon states:
- ⚠️ — sidecar isn't running/reachable (run `./run.sh`)
- 🎙 (outline) — idle, ready
- 🎙 (filled) — recording
- ⏳ — transcribing / cleaning up

## Context-aware cleanup (history + surrounding text)

To make the cleanup pass more accurate — especially for names and technical
terms — it's given two kinds of reference material:

- **Recent dictation history** (option A): the sidecar remembers your last few
  cleaned dictations, so terminology stays consistent across sentences. Kept in
  memory only; cleared when the sidecar restarts.
- **Text before the cursor** (option B): when you stop dictating, the app reads
  the text immediately before the cursor in the focused field (via the
  Accessibility API) and sends it along. This lets the model match capitalization,
  continue a sentence correctly, and fix a mis-heard name to the spelling you've
  already used (e.g. transcript "cavach" → "Kavach").

Both are used as *reference only* — the prompt forbids the model from repeating or
editing them. As a hard guarantee (the small model sometimes ignores that), the
sidecar detects an echo — output much longer than the input, or containing the
reference text verbatim — and automatically re-runs the cleanup with **no**
context or history, which cannot echo. So the pasted text is always just the
current dictation, never previous text. Password/secure fields are never read.

**Privacy:** this reference text is sent only to your **local** Ollama model on
`127.0.0.1` — it never leaves your machine.

## Learning from your edits (personal correction dictionary)

SunoFlow learns the words you keep fixing. When you edit the text it pasted, it
notices the change and remembers it, so it stops making that mistake.

- **How it learns:** right after a paste, the app snapshots the field; at your
  next dictation (or after ~30s) it re-reads the field and diffs it. Small,
  name/term-like substitutions — e.g. `cavach → Kavach`, `jason → JSON`,
  `my sequel → MySQL` — are saved to `sidecar/corrections.json`.
- **How it applies them:** learned corrections are applied deterministically as
  the final step of every transcription, so they always win.
- **What it won't learn:** whole-sentence rewrites (that's you rephrasing, not
  fixing a mishearing) and context-dependent homophones like there/their. It
  biases toward distinctive names, acronyms, and technical terms.
- **Review & control:** the menu bar has a **Learned Corrections** submenu listing
  every pair (with how many times you've made it). Click one to remove it, or
  **Clear All**. Everything is stored locally.

## Auto-start at login (so it survives a reboot)

The sidecar and app don't start themselves after a reboot unless you install the
LaunchAgents:

```bash
./install-autostart.sh
```

This makes both start automatically every time you log in (the sidecar also stays
alive if it ever crashes). To undo it:

```bash
./uninstall-autostart.sh
```

**Important gotcha:** this project lives under `~/Downloads`, which macOS
TCC-protects. A LaunchAgent **cannot** write its log file there — launchd fails to
spawn the whole job with `EX_CONFIG` (78) *before the program even runs*. So the
agents write their logs to `~/Library/Logs/SunoFlow/` instead, not the project
folder. If you ever move this project, keep agent log paths outside
`~/Downloads`, `~/Documents`, and `~/Desktop`.

(Cleanup also needs Ollama running; the Ollama app normally launches at login. If
it isn't running, transcription still works — it just returns the raw transcript
without the LLM cleanup.)

## Code signing (why permissions "stick")

The app is signed with a **stable self-signed certificate** ("SunoFlow
Self-Signed") created by `SunoFlowApp/setup-signing.sh` and stored in your login
keychain. This matters: macOS ties Microphone and Accessibility permissions to
the app's code-signing identity. With ad-hoc signing the identity changes on
every rebuild, so macOS silently revokes those permissions each time. The stable
identity keeps the same designated requirement across rebuilds, so you grant
permissions once and they persist.

If you ever move to a fresh machine, run `./setup-signing.sh` once, then
`./build.sh`.

## Notes & limitations (v1)

- **Apple Silicon only.** The MLX-based STT requires an M-series Mac; Intel Macs
  are not supported.
- The hotkey is a **toggle**, not hold-to-talk (press once to start, again to
  stop) — macOS's global hotkey API only reliably reports key-down events.
  Pressing it again while transcribing cancels; there's also a 60s auto-stop.
- No streaming: the whole utterance is transcribed after you stop recording.
  Parakeet is fast enough that this is normally sub-second for short dictation.
- If the cleanup backend isn't running or reachable, the sidecar falls back to
  the raw (uncleaned) transcript rather than failing.
- The speech model is **downloaded on demand** (~2.5 GB) the first time you open
  the Model tab — it is not bundled with the app. Until it's downloaded,
  transcription returns an empty result.
- The app is self-signed for local use only — it isn't notarized, so it's not
  meant to be distributed outside this machine (yet).
- `app-debug.log` (in the project root) records diagnostics — audio level,
  permission status, transcript *lengths* (not contents). Safe to delete anytime.

## Project structure

```
sunoapp/
├── SunoFlowApp/              # Native Swift menu-bar app (SwiftPM)
│   ├── Sources/SunoFlow/     #   AppDelegate, settings, hotkey, mic, text injection
│   ├── Resources/            #   AppIcon, Info.plist
│   ├── Package.swift
│   ├── build.sh              #   builds + codesigns the .app bundle
│   └── setup-signing.sh      #   one-time: creates the self-signed cert
├── sidecar/                  # Python FastAPI sidecar (on-device STT)
│   ├── server.py             #   /health, /transcribe, /model/*, /corrections, /config
│   └── requirements.txt
├── run.sh / stop.sh          # start / stop sidecar + app together
├── install-autostart.sh      # install login LaunchAgents
└── README.md
```

## License

Proprietary — all rights reserved. This is a personal project; not currently
licensed for redistribution.
