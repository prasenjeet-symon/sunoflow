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
│  • SendInput Ctrl+V text insert    │                  │ HTTPS
│  • UI Automation field context     │                  ▼
└──────────────────────────────────┘        ┌────────────────────────────────┐
                                            │  cleanup.mirrorli.art (Go)     │
                                            │  Bearer-key transcript polish   │
                                            └────────────────────────────────┘
```

| File | Role (mirrors the macOS file) |
|---|---|
| `Program.cs` | Entry point, single-instance lock, "open settings" ping (`main.swift`) |
| `TrayApp.cs` | NotifyIcon + menu, state machine, recording/transcription flow (`AppDelegate.swift`) |
| `HotkeyManager.cs` | System-wide hotkey via a hidden `NativeWindow` + `WM_HOTKEY` (`HotkeyManager.swift`) |
| `HotkeyCaptureForm.cs` | Modal "press a new shortcut" dialog |
| `AudioRecorder.cs` | NAudio capture → 16 kHz mono 16-bit WAV + level meter (`AudioRecorder.swift`) |
| `TextInjector.cs` | Clipboard + `SendInput` Ctrl+V, restores clipboard (`TextInjector.swift`) |
| `EditLearner.cs` | Diff pasted-vs-edited text, POST `/learn` (`EditLearner.swift`) |
| `DictationOverlay.cs` | Floating topmost non-activating waveform bubble (`DictationOverlay.swift`) |
| `TranscriptionClient.cs` | All sidecar HTTP calls (`TranscriptionClient.swift`) |
| `Preferences.cs` | JSON settings in `%LOCALAPPDATA%/SunoFlow/` (`Preferences.swift`) |
| `SettingsForm.cs` | Tabbed settings: Overview, General, Mic, Corrections, AI Cleanup, Model, About (`SettingsView.swift`) |
| `SingleInstance.cs` | Named-mutex lock + loopback TCP "show me" signal |
| `SidecarSupervisor.cs` | Locates + (re)spawns the frozen sidecar when `/health` fails (Windows KeepAlive equivalent) |
| `AutoStart.cs` | HKCU `Run` key management — boot auto-start toggle (LaunchAgent equivalent) |
| `AppLog.cs` | Append-only log to `%LOCALAPPDATA%/SunoFlow/app-debug.log` |
| `Assets/*.ico` | Tray icons (idle/recording/offline/processing/app) |
| `tools/make-icons.js` | Node script that regenerates the `.ico` files |

## Prerequisites

- Windows 10/11 (64-bit) with a DirectX 12 GPU (DirectML serves NVIDIA / AMD / Intel)
- .NET 8 SDK (`net8.0-windows` desktop workload)
- Python 3.10+ for the sidecar (see `sidecars/windows/requirements.txt`)

## Build

```powershell
cd apps\windows\SunoFlow
dotnet build -c Release
# → bin\x64\Release\net8.0-windows\SunoFlow.exe
```

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

   On first run, download the model from the tray app's **Settings → Model** tab
   (or call `POST http://127.0.0.1:8765/model/download`). It lands in
   `%LOCALAPPDATA%\SunoFlow\model` (~2.5 GB).

2. Launch the tray app:
   ```powershell
   .\bin\x64\Release\net8.0-windows\SunoFlow.exe
   ```

3. Press **Alt+Space** (default hotkey) to start/stop dictation. The transcript
   is pasted into whatever field has focus. Rebind the hotkey in Settings.

> **Installed vs dev mode:** when the tray app finds a frozen sidecar at
> `%LOCALAPPDATA%\SunoFlow\sidecar\SunoFlowSidecar\SunoFlowSidecar.exe`, it
> spawns and supervises it automatically (restarting it if it crashes). When
> the exe isn't there (dev), it does nothing and you run the sidecar manually
> as in step 1 above.

## Auto-start at login

In **Settings → General**, toggle **"Start SunoFlow automatically when I log
in"**. This writes/removes an `HKEY_CURRENT_USER\Software\Microsoft\Windows\
CurrentVersion\Run\SunoFlow` entry — no elevation needed (per-user, matching
the macOS per-user LaunchAgent). The registry is the single source of truth, so
the checkbox always reflects what Windows will actually do at boot.

## Sidecar auto-restart

When the frozen sidecar is present, the tray app's 3-second health poll also
respawns it if `/health` fails — the Windows equivalent of the macOS LaunchAgent
`KeepAlive`. A 10-second cooldown prevents a crash loop. The sidecar's
stdout/stderr are teed into `%LOCALAPPDATA%\SunoFlow\sidecar.log` for diagnosis.
On tray-app quit the sidecar is intentionally left running (it's an independent
service — restarting the tray app shouldn't force a model reload).

## Permissions

- **Microphone** — Windows prompts on first capture.
- **UI Automation** — used best-effort to read the focused field for cleanup
  context and edit-learning. No separate permission grant; works out of the box.
- No Accessibility/Screen-Recording-style toggle is needed for `SendInput` paste
  on Windows (unlike macOS's Accessibility gate for `CGEvent`).

## Regenerating the icons

The `.ico` files are PNG-in-ICO (32×32, 32-bit RGBA). To regenerate:

```powershell
node tools\make-icons.js
```

## Status

Built but **not yet validated on a Windows GPU box**. The sidecar's DirectML
binding + GPU latency is the last go/no-go gate (run
`sidecars/windows/validate_onnx.py` on the target box). See `MEMORY.md` for the
full de-risking status. The C# tray app itself can't be compiled on macOS
(no `net8.0-windows` SDK), so it's reviewed-only until built on Windows. The
PyInstaller sidecar bundle (`sidecars/windows/sidecar.spec`) is likewise
reviewed-only until the first `build.ps1` run on Windows. Sidecar auto-spawn /
auto-restart and boot auto-start are implemented in code but await the first
Windows build to confirm end-to-end.