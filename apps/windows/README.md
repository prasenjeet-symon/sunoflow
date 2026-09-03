# SunoFlow for Windows

A system-tray dictation app for Windows. Talk to your computer and it types for
you — speech-to-text runs **on-device** (Parakeet TDT 0.6B v3 via ONNX Runtime +
DirectML); transcript polishing runs on the hosted cleanup gateway.

This is the Windows counterpart of the macOS Swift app (`SunoFlowApp/`). It
talks to the **same** sidecar HTTP contract (`docs/CONTRACT.md`) — only the STT
engine differs (ONNX/DirectML instead of MLX).

## Architecture

```
┌──────────────────────────────────┐        ┌────────────────────────────────┐
│  SunoFlow.exe (this app, C#)     │ HTTP    │  Sidecar (sidecars/windows/)   │
│  WinForms tray app, .NET 8 x64    │◄──────►│  FastAPI on 127.0.0.1:8765      │
│                                  │        │  ONNX Runtime + DirectML STT    │
│  • NotifyIcon tray + state machine│        │  Cleanup → cleanup-gateway     │
│  • Global hotkey (RegisterHotKey) │        └────────────────────────────────┘
│  • NAudio mic → 16k mono WAV       │                  │
│  • SendInput Ctrl+V text insert    │                  │ HTTP
│  • WM_GETTEXT focused-field context│                  ▼
│  • Screen-context OCR (WinRT)      │        ┌────────────────────────────────┐
└──────────────────────────────────┘        │  cleanup-gateway (Go)          │
                                            │  Bearer-key transcript polish   │
                                            └────────────────────────────────┘
```

| File | Role (mirrors the macOS file) |
|---|---|
| `Program.cs` | Entry point, single-instance lock, "open settings" ping (`main.swift`) |
| `TrayApp.cs` | NotifyIcon + menu, state machine, recording/transcription flow (`AppDelegate.swift`) |
| `HotkeyManager.cs` | System-wide hotkey via a hidden `NativeWindow` + `WM_HOTKEY` (`HotkeyManager.swift`) |
| `AudioRecorder.cs` | NAudio capture → 16 kHz mono 16-bit WAV + level meter (`AudioRecorder.swift`) |
| `TextInjector.cs` | Clipboard + `SendInput` Ctrl+V, restores clipboard (`TextInjector.swift`) |
| `EditLearner.cs` | Diff pasted-vs-edited text, POST `/learn` (`EditLearner.swift`) |
| `FocusedField.cs` | Reads the focused field via `WM_GETTEXT` for cleanup context + edit learning; refuses password fields (`AccessibilityContext.swift`) |
| `DictationOverlay.cs` | Floating topmost non-activating waveform bubble (`DictationOverlay.swift`) |
| `TranscriptionClient.cs` | All sidecar HTTP calls (`TranscriptionClient.swift`) |
| `Preferences.cs` | JSON settings in `%LOCALAPPDATA%/SunoFlow/` (`Preferences.swift`) |
| `SettingsForm.cs` | The dashboard: sidebar navigation over Overview, Account, General, Microphone, Speech Model, Dictionary, About (`SettingsView.swift`) |
| `Theme.cs` | Design tokens + the row/button/toggle/field primitives the dashboard is built from (`Theme.swift`) |
| `Glyphs.cs` | The dashboard's line icons, drawn as vectors (the stand-in for SF Symbols) |
| `BrandMark.cs` | The brand mark drawn from the website's SVG path data (`BrandMark.swift`) |
| `AccountManager.cs` | Device pairing + the DPAPI-protected device key (`AccountManager.swift`) |
| `SingleInstance.cs` | Per-session named-mutex lock + a per-user named pipe carrying the "show me" ping |
| `SidecarSupervisor.cs` | Locates + (re)spawns the frozen sidecar when `/health` fails (Windows KeepAlive equivalent) |
| `AutoStart.cs` | HKCU `Run` key management — boot auto-start toggle (LaunchAgent equivalent) |
| `AppLog.cs` | Append-only log to `%LOCALAPPDATA%/SunoFlow/app-debug.log` |
| `ScreenContext.cs` | Screen capture + on-device WinRT OCR for cleanup context (`ScreenContext.swift`) |
| `ForegroundApp.cs` | The frontmost app + focused window title, for cleanup context and app analytics (`ForegroundApp.swift`) |
| `Tone.cs` | The writing voices and their tints; ids are the gateway's (`Tone.swift`) |
| `FocusInspector.cs` | Whether a paste has anywhere to land, from the caret and window class (`FocusInspector.swift`) |
| `TranscriptCard.cs` | The card offering the transcript when nothing was focused (`TranscriptCard.swift`) |
| `BluetoothAudioGuard.cs` | Keeps dictation off a Bluetooth headset mic so its output stays high quality (`BluetoothAudioGuard.swift`) |
| `Assets/*.ico` | Brand-mark icons (idle/recording/offline/processing/app) |
| `tools/make-icons.js` | Node script that rasterises the brand mark into the `.ico` files |

## Prerequisites

- Windows 10/11 (64-bit) with a DirectX 12 GPU (DirectML serves NVIDIA / AMD / Intel) — to **run** it
- .NET 8 SDK — to **build** it, on any OS (see below)
- Python 3.10+ for the sidecar (see `sidecars/windows/requirements.txt`)

## Build

```powershell
cd apps\windows\SunoFlow
dotnet build -c Release -p:Platform=x64
# → bin\x64\Release\net8.0-windows10.0.19041.0\SunoFlow.exe
```

**This project compiles on macOS and Linux too.** `EnableWindowsTargeting` in
the `.csproj` lets the Windows targeting packs restore from NuGet, so
`dotnet build` type-checks the whole tray app from the same machine the Mac app
is developed on — which is where its bugs get written. Running it still needs
Windows. Do not assume a change is safe because it looks right: build it.

`-p:Platform=x64` is what puts the build under `bin\x64\`; without it MSBuild
falls back to `AnyCPU` and the output lands in `bin\Release\` instead. The
target framework is versioned (`net8.0-windows10.0.19041.0`) because the
screen-context OCR needs the Win10 2004 SDK contract — so the framework folder
carries that version, not a bare `net8.0-windows`.

The project is pinned to x64 (`<PlatformTarget>x64</PlatformTarget>`). This keeps
the `SendInput` `INPUT` union's memory layout unambiguous (FieldOffset(8) after
the 4-byte `type` + 4 bytes padding) and matches the target audience (modern
64-bit Windows GPUs).

## Run

There are two ways to run the sidecar. For **end users**, a frozen one-folder
bundle (no Python needed) is built once on a Windows box — see
`sidecars/windows/PACKAGING.md`. For **development**:

1. Start the sidecar first (it serves `127.0.0.1:8765`):
   ```powershell
   cd sidecars\windows
   python -m pip install -r requirements.txt
   python server.py
   ```
   To ship a frozen build instead: `cd sidecars\windows && .\build.ps1`
   → `dist\SunoFlowSidecar\SunoFlowSidecar.exe`, then copy `dist\SunoFlowSidecar\`
   into `%LOCALAPPDATA%\SunoFlow\sidecar\SunoFlowSidecar\`.

   On first run, download the model from the tray app's **Settings → Speech
   Model** page (or call `POST http://127.0.0.1:8765/model/download`). It lands in
   `%LOCALAPPDATA%\SunoFlow\model` (~2.5 GB, or ~0.67 GB where the sidecar
   picks the int8 build for the hardware).

2. Launch the tray app:
   ```powershell
   .\bin\x64\Release\net8.0-windows10.0.19041.0\SunoFlow.exe
   ```

3. Press **Alt+Space** (default hotkey) to start/stop dictation. The transcript
   is pasted into whatever field has focus. Rebind the hotkey in Settings.

> **Connect an account first.** SunoFlow is a subscription product and every
> dictation is checked against the account's trial or subscription, so the app
> refuses to record until this PC is paired. Open **Settings → Account →
> Connect this PC**: a code appears, the browser opens, you approve it there,
> and the key lands in `%LOCALAPPDATA%\SunoFlow\device.key` encrypted with
> DPAPI under your Windows user. Nothing is typed into the app, and it never
> handles your password. **Disconnect this PC** forgets the key locally; to
> actually revoke it, use the dashboard's device list.

> **Installed vs dev mode:** when the tray app finds a frozen sidecar at
> `%LOCALAPPDATA%\SunoFlow\sidecar\SunoFlowSidecar\SunoFlowSidecar.exe`, it
> spawns and supervises it automatically (restarting it if it crashes). When
> the exe isn't there (dev), it does nothing and you run the sidecar manually
> as in step 1 above.

## Auto-start at login

In **Settings → General**, toggle **"Start SunoFlow when I sign in"**. This
writes/removes an `HKEY_CURRENT_USER\Software\Microsoft\Windows\
CurrentVersion\Run\SunoFlow` entry — no elevation needed (per-user, matching
the macOS per-user LaunchAgent). The registry is the single source of truth, so
the checkbox always reflects what Windows will actually do at boot.

## Sidecar auto-restart

When the frozen sidecar is present, the tray app's 3-second health poll also
respawns it if `/health` fails — the Windows equivalent of the macOS LaunchAgent
`KeepAlive`. A 10-second cooldown prevents a crash loop, and it applies to a
sidecar that fails to launch at all, not only to one that starts and dies.

The sidecar's stdout/stderr are teed into `%LOCALAPPDATA%\SunoFlow\sidecar.log`
for diagnosis; it rolls to `sidecar.log.1` at ~1 MB so it keeps the last crash
without growing without bound. A replaced process's handle is released once its
output has finished draining, so a crash's last words still reach the log.

On tray-app quit the sidecar is intentionally left running (it's an independent
service — restarting the tray app shouldn't force a model reload); only the
tray app's handle on it is given up.

## Single instance

A second launch does not start a second tray app — it asks the running one to
open its dashboard, then exits. The lock is a `Local\`-scoped named mutex and the
ping travels over a named pipe whose name carries the logon session and a hash of
the account, opened `CurrentUserOnly` at both ends.

All of that scoping is deliberate: a Windows machine is genuinely multi-user, so
two people signed in at once each get their own tray app and neither can reach
into the other's. (The earlier implementation used a loopback TCP listener on a
fixed port, which is machine-wide — whoever signed in second silently lost the
ping, anything else holding that port broke it, and any local process could pop
the window.)

## Permissions

- **Microphone** — Windows prompts on first capture.
- **Focused-field reading** — `WM_GETTEXT` on the focused control, used
  best-effort for cleanup context and edit-learning. No permission grant is
  involved; it simply returns nothing for controls that don't answer. Password
  fields (`ES_PASSWORD`) are never read.
- No Accessibility/Screen-Recording-style toggle is needed for `SendInput` paste
  on Windows (unlike macOS's Accessibility gate for `CGEvent`).
- **Screen context (optional)** — uses `Windows.Media.Ocr`; no capture permission
  needed for desktop capture (unlike macOS's Screen Recording TCC gate), but an
  OCR language pack must be installed (Settings → Time & Language → Optional
  features). Off by default; enable in Settings → General.

## The dashboard

`SettingsForm.cs` is a port of the macOS dashboard's *design*, not just its
settings. One flat white sheet with a 210px navigation column, hairline rules
instead of group boxes, and rows that run the full width of the column. Every
colour, type size and metric in `Theme.cs` is the same value
`SunoFlowApp/Sources/SunoFlow/Theme.swift` uses, so the two platforms and the
website read as one product.

Nothing on the sheet is a stock WinForms control except the combo boxes and the
text boxes inside `SunoField`: the buttons, switches, steppers, rules, rows,
progress bar and the hotkey recorder are all owner-drawn, because a themed
`Button` or `CheckBox` cannot be made to sit flat on the page. Layout is done by
`Stack`, a one-column layout panel — `FlowLayoutPanel` cannot stretch a row to
the column or wrap a paragraph to it.

The dictation bubble (`DictationOverlay.cs`) is a **layered window**
(`UpdateLayeredWindow` with per-pixel alpha) rather than a borderless form, which
is what gives the capsule real rounded corners and a soft shadow to match the
Mac's `NSPanel`.

## Regenerating the icons

Every icon is the SunoFlow brand mark — an ear receiving sound — in white on a
per-state coloured chip, mirroring the macOS menu bar: idle (ear listening),
recording (filled ear), processing (ear alone), offline (ear struck through),
plus the app icon on the brand violet gradient.

`tools/make-icons.js` holds the mark's SVG path data, copied verbatim from the
website's wordmark (`site/assets/favicon.svg`), and rasterises it — so Windows,
macOS (`SunoFlowApp/Sources/SunoFlow/BrandMark.swift`) and the web app all draw
the same geometry. Edit the mark in one place and re-run all three generators.

The `.ico` files are PNG-in-ICO, 32-bit RGBA, at 16/20/24/32/40/48/64/256 so
Windows has a native size for every DPI. To regenerate:

```powershell
node tools\make-icons.js
```

## Status

**Compiles and packages; not yet validated on a Windows GPU box.**

The tray app compiles on the macOS box this repo is developed on (see Build);
the sidecar half does not, and neither half can be *run* there. CI is still the
authority on the whole tree — `.github/workflows/windows.yml` runs on a
`windows-latest` runner:

- the tray app compiles clean (no warnings) and publishes a self-contained
  `SunoFlow.exe`;
- the sidecar's shared + Windows tests pass on Windows;
- the PyInstaller bundle freezes, and the frozen exe boots and answers
  `/health`.

Both builds are downloadable as run artifacts, so a Windows box can test them
without a toolchain installed.

What CI cannot reach, and what therefore remains open:

- **DirectML — the go/no-go gate.** GitHub's runners have no DX12 GPU. The
  provider is compiled into the bundle and enumerates, but binding and latency
  are unproven; run `sidecars/windows/validate_onnx.py` on the target box.
- **Anything interactive.** A runner has no desktop session, so the hotkey,
  the dictation bubble, clipboard paste, focused-field reading, screen-context
  OCR, sidecar auto-spawn and boot auto-start are compiled but unexercised.
- **Distribution.** There is no installer, no code signing and no update
  channel yet; installation is the manual copy described in
  `docs/BUILD_WINDOWS.md` §6.