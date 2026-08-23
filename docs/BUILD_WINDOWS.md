# Building SunoFlow on Windows

End-to-end guide for cloning the repo onto a Windows machine and building both
parts of the Windows app: the **C# tray app** (`apps/windows/`) and the **Python
sidecar** (`sidecars/windows/`), including the frozen PyInstaller bundle that
end users run without a Python install.

> The two parts are independent and can be built in any order. The tray app
> talks to the sidecar over HTTP (`127.0.0.1:8765`) — see `docs/CONTRACT.md` for
> the wire format. Neither part can be built on macOS (`net8.0-windows` SDK and
> the DirectML provider are Windows-only), so everything below assumes a Windows
> host.

## Prerequisites (one-time)

| Tool | Version | Why | Install |
|---|---|---|---|
| Windows 10/11 **x64** | 10 21H2+ / 11 | WinForms tray app + DirectML | — |
| **DirectX 12 GPU** | NVIDIA / AMD / Intel | DirectML STT (mandatory in production) | — |
| **.NET 8 SDK** | 8.0.x with the *Windows Desktop* workload | Build the C# tray app | <https://dotnet.microsoft.com/download> |
| **Python** | 3.10–3.12, x64 | Build/run the sidecar + PyInstaller freeze | <https://www.python.org/downloads/> |
| **PowerShell** | 5.1+ (in-box) | Run `build.ps1` | — |
| **Git** | any | Clone the repo | <https://git-scm.com> |

Verify the SDK includes the desktop workload:

```powershell
dotnet --list-sdks        # must show an 8.0.x entry
dotnet workload list     # should list "windows-desktop"
# If missing:
dotnet workload install windows-desktop
```

Verify Python is the 64-bit build (DirectML wheels are x64-only):

```powershell
python --version
python -c "import struct; print(struct.calcsize('P')*8)"   # must print 64
```

## 1. Clone

```powershell
git clone <repo-url> C:\dev\sunoapp
cd C:\dev\sunoapp
```

Nothing else needs to be checked out — the model is downloaded on first run
(§4), and icons are committed under `apps/windows/SunoFlow/Assets/`.

## 2. Build the C# tray app

The tray app is a pure WinForms .NET 8 project pinned to **x64** (the `SendInput`
`INPUT` union's memory layout is only correct for the 64-bit target). Its single
third-party dependency is **NAudio 2.2.1** (mic capture + WAV), restored
automatically by the first build.

```powershell
cd apps\windows\SunoFlow
dotnet build -c Release
# → bin\x64\Release\net8.0-windows\SunoFlow.exe
```

Notes:

- The `.ico` icons and `app.manifest` are committed, so `dotnet build` works
  without running `tools\make-icons.js`. You only need Node if you want to
  *regenerate* the icons (`node tools\make-icons.js`) — see
  `apps/windows/README.md`, "Regenerating the icons".
- `DisableWinExeOutputCheck` keeps it a `WinExe` (no console window) when
  launched from Explorer — irrelevant to the build itself.
- There is no publish step required for a dev build. To produce a self-contained
  deployable exe later, see §5.

Smoke test it launches a tray icon:

```powershell
.\bin\x64\Release\net8.0-windows\SunoFlow.exe
```

(At this point the sidecar isn't running, so the tray icon will show "offline"
— that's expected. Start the sidecar in §3 or §4.)

## 3. Run the sidecar in dev mode (Python)

This is the fastest path to a working dictation session on a dev box — no
freezing, you edit Python and restart.

```powershell
cd sidecars\windows
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

`requirements.txt` pins **`onnxruntime-directml`** (the only onnxruntime wheel
you may install — `onnxruntime-gpu` and bare `onnxruntime` are mutually
exclusive with it and would pull CUDA/TensorRT stubs). It also installs
`onnx-asr[hub]` (the STT pipeline), `uvicorn`, `fastapi`,
`python-multipart`, and `requests`.

Confirm DirectML is available on this box:

```powershell
python -c "import onnxruntime as ort; ps=ort.get_available_providers(); print(ps); assert 'DmlExecutionProvider' in ps, 'DirectML EP missing — is this a DX12 GPU?'"
```

Start the sidecar (it serves `127.0.0.1:8765`):

```powershell
python server.py
```

You should see uvicorn start. In another shell, sanity-check the contract:

```powershell
curl http://127.0.0.1:8765/health
# {"status":"ok","model_loaded":false,...}   ← no model yet (download in §4)
```

### 3a. The go/no-go gate: `validate_onnx.py`

Before investing in packaging, confirm the ONNX/DirectML path transcribes real
speech correctly **and** measure latency vs the macOS MLX baseline. This loads
the model directly (no FastAPI) to isolate the STT engine.

```powershell
# Install the harness's extra deps (soundfile + numpy for WAV handling):
python -m pip install soundfile numpy

# Let onnx-asr download nemo-parakeet-tdt-0.6b-v3 from HF into its cache (~2.5 GB, one-time):
python validate_onnx.py --wav C:\path\to\a-speech.wav --runs 3

# Force CPU as a baseline to prove the GPU is actually doing the work:
python validate_onnx.py --wav C:\path\to\a-speech.wav --provider CPUExecutionProvider --runs 3
```

Expected output: the execution provider(s) the session actually bound to, the
transcript, and per-call wall time + RTF (realtime factor). Compare the DirectML
number to the CPU number — DirectML should be faster. The macOS MLX baseline for
a 9 s clip is ~314 ms (RTF 0.035); aim to be in that ballpark. If DirectML is
*slower* than CPU or binds to CPU, the GPU isn't being used — stop and diagnose
before proceeding.

## 4. Download the model (first run)

The Parakeet ONNX model (~2.5 GB, `istupakov/parakeet-tdt-0.6b-v3-onnx`) is **not
bundled**. Download it once, from either:

- the tray app: launch `SunoFlow.exe`, open **Settings → Model → Download**; or
- the sidecar directly:

  ```powershell
  curl -X POST http://127.0.0.1:8765/model/download
  curl http://127.0.0.1:8765/model/status      # poll phase + progress
  ```

It lands in `%LOCALAPPDATA%\SunoFlow\model` (overridable via the
`SUNOFLOW_MODEL_DIR` env var). Once all six files are present
(`encoder-model.onnx`, `encoder-model.onnx.data`, `decoder_joint-model.onnx`,
`nemo128.onnx`, `vocab.txt`, `config.json`), the sidecar loads the model
in-process — no restart needed — and `/health` flips to `model_loaded:true`.

Now press **Alt+Space** (default hotkey) in the tray app to dictate; the
transcript is pasted into the focused field. Rebind the hotkey in Settings.

## 5. Freeze the sidecar for distribution (PyInstaller one-folder)

End users don't have Python. `build.ps1` freezes the sidecar into a
self-contained one-folder bundle.

```powershell
cd sidecars\windows
.\build.ps1
# → dist\SunoFlowSidecar\SunoFlowSidecar.exe
```

`build.ps1` creates a clean `.venv-build`, installs `requirements.txt` +
PyInstaller, and runs `sidecar.spec`. Pass `-Clean:$false` to reuse the venv
across rebuilds.

Why one-folder (not `--onefile`): `onnxruntime` discovers its execution-provider
DLLs (`onnxruntime_providers_directml.dll`, `DirectML.dll`) by path at runtime.
A onefile build extracts to a temp dir not on `PATH`, so provider loading fails.
One-folder keeps every DLL next to the exe. `upx=False` for the same reason —
UPX corrupts onnxruntime DLLs.

The bundle ships with a seed `corrections.json`; on first run `freeze_entry.py`
copies a writable version into `%LOCALAPPDATA%\SunoFlow\` (the bundle dir is
read-only once installed). The model is **not** bundled (keeps the installer
small; downloaded on first run per §4).

### Verify the bundle before shipping

1. Run from a terminal — uvicorn should start on `127.0.0.1:8765`:
   ```powershell
   .\dist\SunoFlowSidecar\SunoFlowSidecar.exe
   ```
2. `curl http://127.0.0.1:8765/health` → `model_loaded:false`.
3. Trigger a model download and confirm `/health` flips to `model_loaded:true`.
4. Dictate a short phrase; confirm a transcript comes back.
5. Confirm `dist\SunoFlowSidecar\` contains `onnxruntime_providers_directml.dll`
   and `DirectML.dll`. If missing, DirectML won't bind and inference falls back
   to CPU — add the DLL explicitly to `sidecar.spec`'s manual DLL scan and
   rebuild.
6. **SSL sanity:** trigger `POST /model/download` and confirm files stream from
   `huggingface.co`. An `SSL: CERTIFICATE_VERIFY_FAILED` means the `certifi`
   `cacert.pem` data file wasn't collected — check
   `dist\SunoFlowSidecar\_internal\certifi\cacert.pem` and add
   `collect_data_files("certifi")` to the spec if absent.

If you hit a `ModuleNotFoundError` at runtime, add the module to `hiddenimports`
in `sidecar.spec` and rebuild. See `sidecars/windows/PACKAGING.md` for the full
correctness notes.

## 6. Install layout (end-user machine)

The frozen sidecar goes to a stable per-user path the tray app knows about:

```
%LOCALAPPDATA%\SunoFlow\
  sidecar\SunoFlowSidecar\        ← copy dist\SunoFlowSidecar\* here
  model\                          ← downloaded on first run (~2.5 GB)
  corrections.json                ← seeded from the bundle on first run
  app-debug.log                   ← tray app log
  preferences.json                ← tray app settings
  sidecar.log                     ← sidecar stdout/stderr (teed by the tray app)
```

Copy the build output:

```powershell
$dst = "$env:LOCALAPPDATA\SunoFlow\sidecar\SunoFlowSidecar"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item -Recurse -Force .\dist\SunoFlowSidecar\* $dst
```

Then place the **published** tray app `SunoFlow.exe` wherever you like (e.g.
`%LOCALAPPDATA%\SunoFlow\SunoFlow.exe`). To publish it self-contained:

```powershell
cd apps\windows\SunoFlow
dotnet publish -c Release -r win-x64 --self-contained true
# → bin\x64\Release\net8.0-windows\win-x64\publish\SunoFlow.exe (+ runtime files)
```

When the tray app finds the sidecar at the path above, it **auto-spawns and
supervises** it (`SidecarSupervisor`): starts it on launch and respawns it when
the 3 s `/health` poll fails (10 s cooldown prevents a crash loop). If the exe
isn't there (dev mode), the supervisor does nothing and you run the sidecar
manually per §3. On tray-app quit the sidecar is intentionally left running.

## 7. Boot auto-start (optional, per-user)

In **Settings → General**, toggle *"Start SunoFlow automatically when I log in"*.
This writes/removes an `HKEY_CURRENT_USER\Software\Microsoft\Windows\
CurrentVersion\Run\SunoFlow` entry — no elevation needed (per-user, matching the
macOS per-user LaunchAgent). The registry is the single source of truth, so the
checkbox always reflects what Windows will actually do at boot.

## 8. Permissions (runtime, not build-time)

- **Microphone** — Windows prompts on first capture.
- **UI Automation** — used best-effort to read the focused field for cleanup
  context and edit-learning. No separate grant; works out of the box.
- No Accessibility/Screen-Recording-style toggle is needed for `SendInput` paste
  on Windows (unlike macOS's Accessibility gate for `CGEvent`).

## 9. Tests (optional, developer-only)

The shared sidecar core has unit tests that run anywhere Python does (they don't
touch the GPU):

```powershell
python -m pip install pytest
python -m pytest sidecars/shared/tests sidecars/windows/tests
```

## Troubleshooting cheat sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `dotnet build` can't find `net8.0-windows` | Desktop workload missing | `dotnet workload install windows-desktop` |
| Python `import onnxruntime` fails on x86 | 32-bit Python | Reinstall Python **x64** |
| `DmlExecutionProvider` not in available providers | No DX12 GPU / old driver | Update GPU drivers; confirm DX12 support |
| DirectML latency ≥ CPU latency | EP fell back to CPU | Check `validate_onnx.py` provider line; ensure provider DLLs are present |
| `/cleanup` returns raw un-cleaned text (no error) | Gateway unreachable / bad key | Soft-fail is by design; check network + `SUNOFLOW_CLEANUP_KEY` env |
| `SSL: CERTIFICATE_VERIFY_FAILED` in frozen bundle | `certifi` `cacert.pem` not collected | Add `collect_data_files("certifi")` to `sidecar.spec` |
| `ModuleNotFoundError` in frozen bundle | Missing hidden import | Add to `hiddenimports` in `sidecar.spec`, rebuild |
| Tray icon shows "offline" | Sidecar not running / not found | Start sidecar (dev: §3) or place frozen bundle at the §6 path |

## Reference

- `apps/windows/README.md` — tray app architecture + run notes
- `sidecars/windows/PACKAGING.md` — full PyInstaller correctness notes
- `docs/CONTRACT.md` — the pinned HTTP contract both sidecars implement
- `MEMORY.md` — full de-risking status, decisions, and gotchas