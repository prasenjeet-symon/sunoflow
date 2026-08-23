# Building SunoFlow on macOS

End-to-end guide for cloning the repo onto an **Apple-Silicon Mac** and building
both parts of the macOS app: the **Swift menu-bar app** (`SunoFlowApp/`) and the
**Python sidecar** (`sidecar/`), then wiring up on-demand model download and
login auto-start the way an end user would.

> The two parts are independent and can be built in any order. The Swift app
> talks to the sidecar over HTTP (`127.0.0.1:8765`) — see `docs/CONTRACT.md` for
> the wire format. **Apple Silicon (M-series) is required**: the sidecar uses
> `parakeet-mlx`, which runs on the MLX framework — MLX is Apple-Silicon-only,
> so Intel Macs are not supported. Speech never leaves the machine; only the
> optional cleanup text is sent to the hosted cleanup gateway (see §9).

## Prerequisites (one-time)

| Tool | Version | Why | Install |
|---|---|---|---|
| **Apple-Silicon Mac** | M1 / M2 / M3 / M4 | MLX STT (Apple-Silicon-only) | — |
| **macOS** | 13.0 Ventura or newer | SwiftUI APIs used by the menu-bar app | — |
| **Xcode Command Line Tools** | Swift 5.9+ | Build the Swift app | `xcode-select --install` |
| **Homebrew Python** | 3.10–3.12 (arm64) | Build/run the sidecar (`parakeet-mlx` needs ≥3.10) | `brew install python@3.12` |
| **Homebrew ffmpeg** | any | `parakeet-mlx` shells out to `ffmpeg` for audio decode | `brew install ffmpeg` |
| **Homebrew openssl** | any | `setup-signing.sh` generates the self-signed cert | `brew install openssl` (or LibreSSL is fine) |
| **Git** | any | Clone the repo | `brew install git` |

Verify you're on Apple Silicon and the toolchain is present:

```bash
uname -m                          # must print arm64
sw_vers                           # ProductVersion ≥ 13.0
swift --version                   # swift-driver version 5.9+
python3.12 --version              # 3.10–3.12
which ffmpeg                      # /opt/homebrew/bin/ffmpeg
```

The sidecar's `requirements.txt` pins `mlx`, `mlx-metal`, `parakeet-mlx`,
`numba`, `librosa`, `fastapi`, `uvicorn`, `python-multipart`, `requests`, and
`huggingface_hub` — all installed automatically in §3.

## 1. Clone

```bash
git clone <repo-url> ~/work/sunoapp
cd ~/work/sunoapp
```

> **Where you clone matters.** macOS TCC-protects `~/Downloads`, `~/Desktop`,
> and `~/Documents`. Shell scripts launched by a LaunchAgent from inside a
> TCC-protected directory fail with "Operation not permitted" / exit 126 — and
> the `com.apple.provenance` xattr on freshly-created files cannot be removed.
> If you must clone under `~/Downloads`, the bundled `install-autostart.sh`
> still works (it invokes the venv `python` binary directly, not a `.sh`), but
> any *shell script* you add later and launch via launchd will break. Cloning
> into `~/work/` or `~/src/` avoids the whole class of problem.

Nothing else needs to be checked out — the Parakeet model is downloaded on
first run (§5), and the app icon (`Resources/AppIcon.icns`) is committed. To
regenerate it, run `SunoFlowApp/tools/make-icns.sh`: it draws the brand mark
from `Sources/SunoFlow/BrandMark.swift` — the same SVG paths the website and the
menu-bar icon use — at every size the iconset needs.

## 2. Build the Swift menu-bar app

The app is a SwiftUI menu-bar app (`NSStatusItem`, no Dock icon — `LSUIElement`
is `true` in `Info.plist`). It has **no third-party Swift dependencies** — the
`Package.swift` is a single executable target. All native integration (Carbon
global hotkey, `AVAudioEngine` mic capture, `CGEvent` Cmd+V paste, Vision OCR)
uses system frameworks.

```bash
cd SunoFlowApp
swift build -c release
```

### Assemble the .app bundle + code-sign it

`build.sh` assembles `SunoFlow.app` from the release binary + `Info.plist` +
icon, and signs it. Run **`setup-signing.sh` once first** to create a stable
self-signed identity — otherwise `build.sh` falls back to ad-hoc signing and
**macOS revokes your Microphone + Accessibility permissions on every rebuild**
(ad-hoc signing gives a new code identity each build, so TCC treats each
rebuild as a brand-new app).

```bash
./setup-signing.sh        # one-time: creates "SunoFlow Self-Signed" in login keychain
./build.sh
# → SunoFlowApp/SunoFlow.app
```

Verify the signing identity is present:

```bash
security find-identity -p codesigning | grep "SunoFlow Self-Signed"
```

`build.sh` signs `--deep` with that identity when found, and prints a warning +
falls back to `codesign -s -` otherwise. The app targets macOS 13+
(`LSMinimumSystemVersion = 13.0`), Apple Silicon (arm64).

Smoke test it launches a menu-bar icon:

```bash
open SunoFlowApp/SunoFlow.app
```

(At this point the sidecar isn't running, so the mic icon will show "offline" —
expected. Start the sidecar in §3.)

## 3. Run the sidecar in dev mode (Python)

This is the fastest path to a working dictation session on a dev box — no
freezing, you edit Python and restart. Use Homebrew's arm64 Python (macOS's
bundled 3.9 is too old for `parakeet-mlx`).

```bash
cd sidecar
/opt/homebrew/bin/python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

Confirm MLX is available and on the Metal backend:

```bash
python -c "import mlx; import mlx.core as mx; print(mx.default_device())"
# Device(gpu, 0)   ← Metal GPU. If it prints Device(cpu, 0), MLX fell back — check you're on Apple Silicon.
```

Start the sidecar (it serves `127.0.0.1:8765`):

```bash
python server.py
```

You should see uvicorn start. In another shell, sanity-check the contract:

```bash
curl http://127.0.0.1:8765/health
# {"status":"ok","model_loaded":false,...}   ← no model yet (download in §5)
```

### 3a. Quick STT sanity (optional, before downloading the full model)

The macOS path has no separate `validate_onnx.py` harness — the sidecar *is*
the test. Once the model is downloaded (§5), a single `/transcribe` call with a
short WAV confirms the MLX pipeline end-to-end. Skip this until §5.

## 4. Use the dev launcher (`run.sh`)

For day-to-day dev, `run.sh` starts the sidecar (if not already running), waits
for `/health`, builds the `.app` if missing, and launches it:

```bash
cd ~/work/sunoapp
./run.sh
```

It writes `sidecar.pid` and logs to `sidecar.log` in the repo root. Stop both
with `./stop.sh` (quits the app via AppleScript, kills the sidecar by pid).

## 5. Download the model (first run)

The Parakeet MLX model (`mlx-community/parakeet-tdt-0.6b-v3`, ~1.6 GB of
safetensors) is **not bundled**. Download it once, from either:

- the app: launch `SunoFlow.app`, open **Settings → Model → Download**; or
- the sidecar directly:

  ```bash
  curl -X POST http://127.0.0.1:8765/model/download
  curl http://127.0.0.1:8765/model/status      # poll phase + progress
  ```

It streams from `huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/<file>`
into `~/Library/Application Support/SunoFlow/model` (overridable via the
`SUNOFLOW_MODEL_DIR` env var). Once all five files are present (`config.json`,
`model.safetensors`, `tokenizer.model`, `tokenizer.vocab`, `vocab.txt`), the
sidecar loads the model in-process via `parakeet_mlx.from_pretrained(MODEL_DIR)`
— no sidecar restart needed — and `/health` flips to `model_loaded:true`.

Now press **Option+Space** (default hotkey) in the menu bar to dictate; the
transcript is pasted into the focused field. Rebind the hotkey in Settings.

### Verify STT end-to-end

Record a short clip and transcribe it:

```bash
say "Hello world, this is a test." -o /tmp/test.aiff && ffmpeg -y -i /tmp/test.aiff /tmp/test.wav
curl -s -X POST -F "file=@/tmp/test.wav" http://127.0.0.1:8765/transcribe | python -m json.tool
```

You should see `{"raw": "...", "cleaned": "..."}`. A warm 9 s clip transcribes
in ~314 ms (RTF 0.035) on an M-series Mac.

## 6. Install the app into /Applications (end-user layout)

For an end-user install, copy the built `.app` into `/Applications` so both the
user and the LaunchAgent run the same copy:

```bash
cp -R SunoFlowApp/SunoFlow.app /Applications/SunoFlow.app
```

The sidecar's on-disk layout for an end user:

```
~/Library/Application Support/SunoFlow/
  model/                                  ← downloaded on first run (~1.6 GB)
sidecar/corrections.json                  ← learned corrections (lives in repo / install dir)
~/Library/Logs/SunoFlow/                  ← sidecar.log + app.log (LaunchAgent-managed)
```

The sidecar itself stays wherever you cloned/installed it — the LaunchAgent
(§7) points at the venv `python` + `server.py` by absolute path. Unlike the
Windows track, there is **no PyInstaller freeze step** for the macOS sidecar in
this guide — the distribution plan is to freeze it with PyInstaller (one-folder
mode for MLX/numba tolerance) and bundle into `SunoFlow.app/Contents/Resources/
sidecar/`, but that is not yet wired into `build.sh`. For now, end users run
from the venv as set up in §3.

## 7. Boot auto-start (LaunchAgents, per-user)

`install-autostart.sh` writes two per-user LaunchAgents that start the sidecar
and the app at login (the sidecar also stays alive via `KeepAlive`):

```bash
./install-autostart.sh
```

This creates:

- `~/Library/LaunchAgents/com.sunoapp.sunoflow.sidecar.plist` — runs the venv
  `python server.py` with `PATH=/opt/homebrew/bin:...` (so `parakeet-mlx` finds
  `ffmpeg`), `RunAtLoad=true`, `KeepAlive=true`, logs to
  `~/Library/Logs/SunoFlow/sidecar.log`.
- `~/Library/LaunchAgents/com.sunoapp.sunoflow.app.plist` — runs the app
  binary, `RunAtLoad=true`, `KeepAlive=false` (you can quit it; it won't respawn
  until next login).

`install-autostart.sh` **prefers the installed `/Applications/SunoFlow.app`**
when present and falls back to the repo's dev build (`SunoFlowApp/SunoFlow.app`)
otherwise — so re-running it never silently points launchd at a stale dev
build. It prints which binary it picked.

Remove auto-start later with `./uninstall-autostart.sh` (bootouts both jobs and
deletes the plists; the app is still runnable via `./run.sh`).

### Reload after a rebuild (`redeploy.sh`)

After rebuilding the app with `build.sh`, the on-disk binary gets a new code
hash, and `launchctl kickstart -k` on the app job fails with an
`OS_REASON_CODESIGNING` "spawn failed" because launchd cached the *old* hash —
even though the binary is valid and launches fine directly. `redeploy.sh` does
the build + the correct bootout/bootstrap-fresh dance for you:

```bash
./redeploy.sh
```

Use this instead of `kickstart -k` whenever you've rebuilt the Swift app and are
running under the LaunchAgent. The sidecar job has no such issue and restarts
with a plain `kickstart -k`.

## 8. Permissions (runtime, not build-time)

macOS will prompt on first use; grant these in **System Settings → Privacy &
Security**:

- **Microphone** — first capture. Required. Without it, `AVAudioEngine` returns
  silence.
- **Accessibility** — required for `CGEvent` Cmd+V paste and for
  `AXUIElement` edit-learning. Without it, dictation transcribes but nothing
  gets typed into the focused field.
- **Screen Recording** (optional) — only if **Settings → Screen Context** is
  ON. The app captures the main display and runs Vision OCR (`.fast`) to
  extract on-screen words as cleanup context. Without permission,
  `CGDisplayCreateImage` returns a **black image, not nil** — so the app
  preflights with `CGPreflightScreenCaptureAccess()` and silently skips if
  missing (does not block dictation). `ScreenContext.openSystemSettings()`
  opens the right pane and registers with TCC.

> **Stable signing (§2) is what keeps these grants across rebuilds.** Ad-hoc
> signing resets them every rebuild. This is why `setup-signing.sh` exists.

## 9. Cleanup service (hosted, optional but default-on)

The cleanup/LLM step that fixes disfluencies, punctuation, and names runs on a
**remote hosted gateway**, not locally — end users do **not** install or run
Ollama. The sidecar POSTs `{text, context, recent, screen}` to
`https://cleanup.mirrorli.art/cleanup` (Bearer-authed) and soft-fails to raw
text on any error (network/auth/timeout/non-200) — dictation never breaks
because cleanup is down. The Swift app probes `https://cleanup.mirrorli.art/ready`
for its connectivity status card in Settings.

Override the gateway for dev (e.g. point at a local `docker-compose` stack):

```bash
export SUNOFLOW_CLEANUP_URL=http://127.0.0.1:8081/cleanup
export SUNOFLOW_CLEANUP_KEY=<a-key-you-issued>
python server.py
```

See `docs/CLEANUP_GATEWAY_ARCHITECTURE.md` for the backend design and
`cleanup-gateway/` for the Go service.

## 10. Tests (optional, developer-only)

The shared sidecar core has unit tests that run anywhere Python does (they
don't touch the GPU):

```bash
python -m pip install pytest
python -m pytest sidecars/shared/tests
```

(The macOS sidecar has no macOS-specific test directory — the shared tests cover
the platform-agnostic corrections + cleanup-gateway POST logic that
`sidecar/server.py` shares with `sidecars/mac/`.)

## Troubleshooting cheat sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `swift build` fails / no Swift 5.9 | Command Line Tools missing/old | `xcode-select --install` |
| `import mlx` fails or `Device(cpu, 0)` | On Intel Mac, or wrong Python | Apple Silicon required; use `/opt/homebrew/bin/python3.12` |
| `parakeet-mlx` install fails | Python < 3.10 | Use Homebrew Python 3.10–3.12 |
| Sidecar `ffmpeg not found` | ffmpeg not on launchd's PATH | `brew install ffmpeg`; the LaunchAgent plist sets `PATH=/opt/homebrew/bin:...` |
| Mic/Accesibility perms reset every rebuild | Ad-hoc signing | Run `SunoFlowApp/setup-signing.sh` once, then `build.sh` signs with the stable identity |
| LaunchAgent sidecar exits 126 | Sidecar script under `~/Downloads` (TCC) | Clone outside TCC dirs, or rely on the venv-python invocation (works from Downloads) |
| `launchctl kickstart -k` app job → "spawn failed" | launchd cached old code hash after rebuild | Use `./redeploy.sh` (bootout + bootstrap-fresh), not `kickstart -k` |
| App starts stale dev build on reboot | App plist points at repo dev build | Re-run `./install-autostart.sh` — it now prefers `/Applications/SunoFlow.app` over the dev build automatically |
| Dictation transcribes but nothing pastes | Accessibility not granted | System Settings → Privacy & Security → Accessibility → add SunoFlow |
| Screen context always empty | Screen Recording not granted | Settings → Screen Context ON; grant Screen Recording (note: black image, not nil, without it) |
| `/cleanup` returns raw un-cleaned text (no error) | Gateway unreachable / bad key | Soft-fail is by design; check network + `SUNOFLOW_CLEANUP_KEY` env |
| `/health` says `model_loaded:false` forever | Model download incomplete | `curl http://127.0.0.1:8765/model/status`; ensure all 5 files present in `~/Library/Application Support/SunoFlow/model` |

## Release build — notarized DMG (shippable)

The dev flow above (build.sh + ad-hoc signing + a manually-run Python sidecar) is for
local development. For a build you can hand to end users, use `release.sh` at the repo
root instead. It produces a self-contained, notarized, stapled DMG that opens cleanly
under Gatekeeper on a clean Mac.

### One-time setup

1. A **Developer ID Application** certificate in your keychain (from the Apple
   Developer Program). This is NOT the self-signed identity from `setup-signing.sh` —
   that's dev-only and won't satisfy Gatekeeper.
2. Notarization credentials. The simplest is a stored keychain profile:
   ```bash
   xcrun notarytool store-credentials SunoFlow \
       --apple-id you@example.com --team-id ABCDEF1234 --password <app-specific-pw>
   ```
   This stores them in the keychain so you never type the password again. Then set
   `SUNOFLOW_NOTARY_PROFILE=SunoFlow` at release time. Alternatively pass
   `SUNOFLOW_APPLE_ID` + `SUNOFLOW_TEAM_ID` + `SUNOFLOW_APP_PW` directly.

### Build the release

```bash
# From the repo root:
export SUNOFLOW_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDEF1234)"
export SUNOFLOW_NOTARY_PROFILE=SunoFlow
./release.sh                       # version taken from Info.plist
# or: ./release.sh 1.2.3            # explicit version
# → SunoFlow-<version>.dmg
```

What `release.sh` does (full detail in `docs/RELEASE_PLAN.md`, Phase 4):

1. `swift build -c release` → the Swift executable.
2. Assembles `SunoFlow.app` (`Contents/MacOS`, `Contents/Resources`, `Info.plist`,
   `AppIcon.icns`).
3. Bundles the **PyInstaller-frozen sidecar** into
   `Contents/Resources/sidecar/SunoFlowSidecar/` — running `sidecar/build.sh`
   automatically if the frozen output is missing. No Python/venv needed at runtime.
4. Signs **inside-out** with the hardened runtime + `SunoFlowApp/Entitlements.plist`:
   the frozen sidecar bundle first (its own entitlements — it loads unsigned MLX/numba
   dylibs), then the outer `.app` (the mic entitlement).
5. Zips → `notarytool submit --wait` → `stapler staple` the `.app`.
6. `hdiutil` → the DMG.
7. Signs + notarizes + staples the DMG too (Apple recommends notarizing both).

The app owns the sidecar lifecycle at runtime (`SidecarSupervisor.swift` spawns and
supervises the bundled frozen binary — no launchd plist for the sidecar in a
distributed build). The model (~2.4 GB) is NOT bundled; the user downloads it on
first run from Settings → Model.

### Dev-only / no-cert mode

If `SUNOFLOW_SIGN_IDENTITY` is unset (or the identity isn't in the keychain),
`release.sh` falls back to ad-hoc signing and **skips** notarization — producing an
unsigned DMG for local testing only. This lets the script run on a dev box before the
Developer ID cert exists.

## Reference

- `README.md` — project overview + the architecture diagram
- `docs/CONTRACT.md` — the pinned HTTP contract the sidecar implements
- `docs/CLEANUP_GATEWAY_ARCHITECTURE.md` — the hosted cleanup backend design
- `docs/BUILD_WINDOWS.md` — the Windows equivalent of this guide
- `MEMORY.md` — full decisions, gotchas, and de-risking status