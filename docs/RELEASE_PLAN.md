# SunoFlow — Notarized DMG Release Plan

**Goal:** ship a self-contained, notarized macOS `.app` inside a DMG that opens
without the "unidentified developer" warning on any end-user's Mac (Apple
Silicon only). The app must work from `/Applications` with **zero dependence on
the developer's source tree** (`~/Downloads/work/sunoapp`), no `run.sh`, no
`.venv`, and no hand-installed LaunchAgent plists.

**Distribution model:** direct download (DMG via GitHub Releases). NOT the App
Store — the embedded Python sidecar violates mandatory App Sandbox rules, and
porting STT to Swift/mlx-swift is out of scope for v1.

---

## The core problem

The app currently assumes a developer tree exists on disk:

| Dev dependency | Where it lives | Breaks for end users because |
|---|---|---|
| `AppLog.fileURL` → `~/Downloads/work/sunoapp/app-debug.log` | `Logger.swift` | users have no such dir; logging fails silently |
| `projectRoot()` walks up looking for `run.sh` | `SettingsView.swift` | a distributed `.app` has no `run.sh` ancestor → always `nil` |
| `startEngine()` runs `/bin/bash run.sh` | `SettingsView.swift` | no `run.sh`, no `.venv` in a shipped bundle |
| `openProjectFolder()` opens the repo in Finder | `SettingsView.swift` | no "project folder" exists for users |
| Status text `"sidecar offline (run ./run.sh)"` | `AppDelegate.swift` | user-facing string references dev tooling |
| Sidecar lifecycle = external launchd plist (`com.sunoapp.sunoflow.sidecar`) | `install-autostart.sh` | not installed for end users; nothing keeps the sidecar alive |
| Sidecar runtime = `sidecar/.venv/bin/python server.py` | `run.sh` | users have no Python/venv; sidecar must be a frozen binary |

Everything else — `TranscriptionClient` (localhost:8765 + hosted gateway),
`LoginItem` (`SMAppService`), `ScreenContext`, `Preferences`, the recording
flow — is already distribution-safe and needs no change.

---

## Phase 1 — Remove dev-tree dependencies (pure Swift edits)

**Verifiable immediately with `swift build`.** No new infrastructure, no frozen
sidecar, no signing. This is the low-risk foundation.

1. **`Logger.swift`** — move the log file to `~/Library/Logs/SunoFlow/app-debug.log`
   (TCC-safe, the conventional location). Use
   `FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)` and
   append `Logs/SunoFlow/`. Create the directory if missing.

2. **`AppDelegate.swift`** — change the `.sidecarOffline` status string from
   `"Status: sidecar offline (run ./run.sh)"` to
   `"Status: speech engine offline"`.

3. **`SettingsView.swift`** —
   - Replace `projectRoot()` (walks up for `run.sh`) with
     `sidecarBinaryURL()` → `Bundle.main.bundleURL/Contents/Resources/sidecar/SunoFlowSidecar`.
   - Rewrite `startEngine()` to launch the **bundled frozen sidecar binary**
     directly as a detached `Process` (`launchPath` = sidecar exe,
     `workingDirectory` = its parent dir), then poll `/health` as today. This
     becomes a thin wrapper around `SidecarSupervisor.shared.ensureRunning()`
     once Phase 2 lands; for now it just spawns the binary and polls.
   - Remove `openProjectFolder()` and its "Project folder" button in the
     About → Resources section (keep "View logs" + the upstream links).
   - The "Start engine" buttons (Overview card + Model tab) stay — they now
     launch the bundled sidecar instead of `run.sh`.

4. **`Info.plist`** —
   - Bump `CFBundleShortVersionString` → `1.0.0`, `CFBundleVersion` → `1`.
   - Add `NSScreenCaptureUsageDescription` (Screen Recording is requested by
     `ScreenContext.swift`; macOS requires a usage string for the TCC prompt).
   - Keep `NSMicrophoneUsageDescription`.

**Exit criteria:** `swift build` clean; the app no longer references
`~/Downloads/work/sunoapp`, `run.sh`, or `.venv` anywhere in its source.

---

## Phase 2 — App owns the sidecar lifecycle (new `SidecarSupervisor.swift`)

**The single biggest functional gap.** In dev, an external launchd plist
(`com.sunoapp.sunoflow.sidecar`, `KeepAlive=true`) keeps the sidecar alive. A
distributed app has no such plist — the app itself must spawn the bundled
frozen sidecar and respawn it if it dies. This mirrors the Windows
`SidecarSupervisor.cs` already built for the Windows tray app.

1. **New file `SunoFlowApp/Sources/SunoFlow/SidecarSupervisor.swift`** —
   - Singleton (`SidecarSupervisor.shared`).
   - Locates the bundled frozen sidecar at
     `Bundle.main.bundleURL/Contents/Resources/sidecar/SunoFlowSidecar`.
   - `isAvailable: Bool` — true when the frozen binary exists (installed mode);
     false in dev (no binary → no-op, user runs the sidecar manually, exactly
     as today). This keeps dev workflows intact.
   - `ensureRunning()` — spawns the sidecar as a detached `Process` if not
     already running and not within a respawn cooldown (10s, to avoid a crash
     loop). Tees stdout/stderr into `~/Library/Logs/SunoFlow/sidecar.log` so a
     frozen-bundle startup failure is diagnosable (the binary has no console
     when launched by the app).
   - On app quit the sidecar is **left running** (it's an independent service;
     killing it would force a slow model reload on next launch). The health
     loop restarts it if it dies.

2. **`AppDelegate.swift`** —
   - In `applicationDidFinishLaunching`, call
     `SidecarSupervisor.shared.ensureRunning()` before `startHealthPolling()`.
   - In `checkHealth()`, when health fails, call
     `SidecarSupervisor.shared.ensureRunning()` (respawns the sidecar).
   - This replaces the external launchd `KeepAlive` for end users.

3. **`SettingsView.swift`** — simplify `startEngine()` to delegate to
   `SidecarSupervisor.shared.ensureRunning()` (the polling loop stays for UI
   feedback).

4. **`LoginItem.swift`** — update the doc comment: it currently references
   `install-autostart.sh` as the sidecar auto-start mechanism. Reword to say
   the app supervises the sidecar itself (Phase 2) and this file only governs
   the *app's* login-item registration.

**Exit criteria:** with a frozen sidecar at
`Contents/Resources/sidecar/SunoFlowSidecar`, launching the `.app` starts the
sidecar automatically; killing the sidecar process causes the app to respawn
it within ~3s (one health-poll cycle + cooldown). In dev (no frozen binary),
the supervisor is a no-op and the manual `run.sh` workflow still works.

---

## Phase 3 — PyInstaller freeze of the sidecar

**Users cannot have a `.venv` or Python installed.** The sidecar must be a
self-contained binary inside the `.app`. This mirrors the Windows track
(`sidecars/windows/sidecar.spec`, `freeze_entry.py`, `PACKAGING.md`).

1. **New `sidecar/sidecar.spec`** (PyInstaller, one-folder, `upx=False`) —
   - Entry point: `freeze_entry.py`.
   - `collect_submodules` for the MLX/parakeet/numpy/librosa/scipy stack;
     `collect_dynamic_libs` for the Metal/MLX dylibs.
   - `target_arch="arm64"` (Apple Silicon only — MLX is arm64-only).
   - Ships a seed `corrections.json`.
   - **Model NOT bundled** (~2.4 GB) — downloaded on demand to
     `~/Library/Application Support/SunoFlow/model` via the existing Settings →
     Model flow. Keeps the installer small.

2. **New `sidecar/freeze_entry.py`** — frozen-aware entry point that resolves
   a **writable** `corrections.json` in
   `~/Library/Application Support/SunoFlow/` (seeds from the bundled copy on
   first run) and a writable model dir, then launches the FastAPI app. Mirrors
   `sidecars/windows/freeze_entry.py`.

3. **New `sidecar/build.sh`** — venv → install `requirements.txt` →
   `pyinstaller sidecar.spec` one-liner. Produces
   `sidecar/dist/SunoFlowSidecar/` (one-folder bundle).

4. **`sidecar/PACKAGING.md`** — document the freeze recipe + the writable-path
   decisions (mirrors `sidecars/windows/PACKAGING.md`).

**Cannot be fully tested on this Mac without a clean venv freeze run**, but
the spec + entry point can be written and `py_compile`-checked now. The actual
freeze + smoke-test happens in Phase 4's `release.sh` dry run.

**Exit criteria:** `sidecar/build.sh` produces a `SunoFlowSidecar` executable
that starts the FastAPI server and serves `/health` + `/transcribe` with no
Python installed on the system.

---

## Phase 4 — Notarization plumbing (Entitlements + `release.sh`)

**The final packaging step.** Self-signed/ad-hoc code is rejected by
Gatekeeper; notarization + Developer ID + hardened runtime are mandatory for a
DMG that opens cleanly.

1. **New `SunoFlowApp/Entitlements.plist`** —
   - `com.apple.security.cs.disable-library-validation` — the PyInstaller
     sidecar bundles its own MLX/numba/Metal dylibs that we do not sign
     individually; hardened runtime blocks unsigned libraries by default.
   - `com.apple.security.cs.allow-unsigned-executable-memory` — Python/numba
     may need it.
   - `com.apple.security.device.audio-input` — microphone.
   - (NOT `com.apple.security.app-sandbox` — we are NOT sandboxed; direct
     distribution, not App Store.)

2. **New `release.sh`** (repo root) — the single release-build script:
   1. `swift build -c release` (the app executable).
   2. Assemble `SunoFlow.app` bundle (`Contents/MacOS`, `Contents/Resources`).
   3. Copy `Info.plist`, `AppIcon.icns`, the release executable.
   4. Bundle the PyInstaller-frozen sidecar into `Contents/Resources/sidecar/`
      (run `sidecar/build.sh` if the frozen output is missing).
   5. Sign with hardened runtime + the entitlements:
      `codesign --force --deep --options runtime --entitlements Entitlements.plist
      --sign "Developer ID Application: <name>" SunoFlow.app`
   6. `xcrun notarytool submit SunoFlow.app.zip --apple-id … --team-id … --wait`
   7. `xcrun stapler staple SunoFlow.app`
   8. `hdiutil create -volname SunoFlow -srcfolder SunoFlow.app -fs APFS
      SunoFlow-1.0.0.dmg`
   9. Sign + notarize + staple the DMG too (Apple recommends notarizing both).
   - Reads credentials from env vars (`SUNOFLOW_APPLE_ID`,
     `SUNOFLOW_TEAM_ID`, `SUNOFLOW_NOTARY_KEYCHAIN_PROFILE`) — never committed.

3. **`build.sh`** — keep as the dev-only ad-hoc build script (unchanged; it's
   still useful for local dev builds that don't need notarization). `release.sh`
   is the production counterpart.

4. **Dev-only scripts** (`run.sh`, `stop.sh`, `install-autostart.sh`,
   `uninstall-autostart.sh`, `redeploy.sh`) — **no source change**, but these
   are NOT shipped. The sidecar LaunchAgent plist
   (`com.sunoapp.sunoflow.sidecar`) is no longer installed for end users —
   `SidecarSupervisor` replaces it. The app LaunchAgent can stay (`SMAppService`
   or the existing plist).

**Exit criteria:** `release.sh` produces a notarized, stapled
`SunoFlow-1.0.0.dmg` that opens on a clean Mac without a "unidentified
developer" warning, and the bundled app starts the sidecar automatically with
no Python/venv on the system.

---

## Implementation order

```
Phase 1  ──►  Phase 2  ──►  Phase 3  ──►  Phase 4
(pure       (new file +     (PyInstaller     (entitlements +
 Swift,     wiring; needs   freeze of the    notarization +
 build-     a frozen        sidecar; can't   DMG — the final
 able now)  sidecar to      fully test on    release step)
            test fully)     this Mac without
                            a clean venv)
```

- **Phase 1** is independent and build-verifiable immediately. Do it first.
- **Phase 2** compiles clean without Phase 3 (the supervisor is a no-op when
  no frozen binary exists), but can only be *tested end-to-end* after Phase 3.
- **Phase 3** is the riskiest step (PyInstaller + MLX/Metal dylibs +
  one-folder layout). It's also the gate for Phase 2's full test.
- **Phase 4** requires a Developer ID certificate + Apple Developer account
  (notarization credentials). The script can be written now but only run once
  the cert exists.

## Out of scope (explicitly)
- App Store submission (sandbox-incompatible).
- Sparkle auto-updates (deferred to v1.1).
- Windows / Android builds (separate tracks; Windows is already built).
- Porting STT to Swift/mlx-swift (would enable App Store, multi-week effort).