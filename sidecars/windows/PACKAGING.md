# Windows sidecar — PyInstaller packaging

This freezes the SunoFlow Windows sidecar (FastAPI + ONNX Runtime/DirectML +
onnx-asr) into a self-contained one-folder bundle the end user can run without
installing Python or any pip packages.

> PyInstaller is **not a cross-compiler**. You must build the bundle on a
> Windows box; it cannot be produced on the macOS box this repo is developed
> on. If you don't have one to hand, `.github/workflows/windows.yml` runs this
> build on a `windows-latest` runner and uploads the bundle as an artifact —
> that is how the spec was first proven, and it boots and answers `/health`
> there. A GPU is not needed to *build* the bundle, only to run inference on
> it.

## Quick build

```powershell
cd sidecars\windows
.\build.ps1
# → dist\SunoFlowSidecar\SunoFlowSidecar.exe
```

`build.ps1` creates a clean venv (`.venv-build`), installs `requirements.txt`
+ PyInstaller, and runs the spec. Pass `-Clean:$false` to reuse the venv.

## Files

| File | Purpose |
|---|---|
| `freeze_entry.py` | Frozen-aware entry point. Resolves a **writable** `corrections.json` in `%LOCALAPPDATA%\SunoFlow\` (the bundle dir is read-only for an installed app), seeds it from the bundled copy on first run, then boots uvicorn. The dev `server.py` uses a repo-root `sys.path` hack that doesn't apply when frozen. |
| `sidecar.spec` | PyInstaller spec. Collects onnxruntime/onnx-asr/huggingface_hub submodules + native DLLs (incl. the DirectML provider, which is loaded by name at runtime and which static analysis misses), plus the uvicorn/starlette/fastapi/multipart web stack. |
| `build.ps1` | One-command build script (venv → install → freeze). |

## Why one-folder, not one-file

`onnxruntime` discovers its execution-provider DLLs (`DirectML.dll`, `onnxruntime_providers_shared.dll`) by path at runtime via `ctypes`/`os.add_dll_directory`. A `--onefile` build extracts to a temp dir that is not on `PATH`, so provider loading fails. The one-folder layout keeps every DLL next to the exe, which is exactly where onnxruntime looks. `upx=False` for the same reason — UPX can corrupt onnxruntime's DLLs.

## What is and isn't bundled

**Bundled:** the Python interpreter, all pip deps (onnxruntime-directml, onnx-asr, fastapi, uvicorn, starlette, requests, huggingface_hub, pydantic, python-multipart), the onnxruntime native DLLs (`onnxruntime.dll`, `onnxruntime_providers_shared.dll`, `DirectML.dll`), and a seed `corrections.json`.

**Not bundled:** the Parakeet ONNX model (~2.5 GB full precision, or ~0.67 GB
for the int8 build a PC without a suitable GPU gets — the sidecar probes the
hardware and picks, see `docs/BUILD_WINDOWS.md`). The user downloads it on first run from the tray app's **Settings → Model** tab (or `POST /model/download`). It lands in `%LOCALAPPDATA%\SunoFlow\model`, which is stable across sidecar upgrades so a reinstall doesn't force a re-download. This keeps the installer small and lets users defer the big download.

## Correctness notes

- **`collect_submodules('onnxruntime')`** is safe with the `onnxruntime-directml` wheel: the CUDA/TensorRT provider stubs are not installed, so they can't be dragged in. With `onnxruntime-gpu` or bare `onnxruntime` they would be — do not mix those wheels.
- **Manual DirectML DLL scan** in the spec: `collect_dynamic_libs('onnxruntime')` catches the `.pyd`/core `.dll`s, but `DirectML.dll` in the wheel root is sometimes classified as data. The manual scan guarantees it lands in `binaries`, not `datas`, so it ships as a real DLL.
- **`python-multipart`** imports as `multipart`. It's only imported when a `Form()`/`File()` route is hit (the `/transcribe` upload), so PyInstaller's static analysis misses it — it's listed explicitly.
- **`certifi` data file (`cacert.pem`)** is collected explicitly. Without it, the model download (`POST /model/download` → HTTPS to `huggingface.co`) fails with SSL certificate errors in the frozen bundle, because PyInstaller's static analysis does not pick up the data file certifi locates via `importlib.resources` at runtime.
- **`requests`/`urllib3`/`tqdm`/`platformdirs`/`filelock`** are collected defensively. The model-download path uses `requests`, and `huggingface_hub` conditionally pulls in `tqdm` for progress bars plus `platformdirs`/`filelock`. These transitive deps are common first-build misses because they're reached via dynamic imports.

## Verifying the bundle

After building, before shipping:

1. Run `dist\SunoFlowSidecar\SunoFlowSidecar.exe` from a terminal. You should see uvicorn start on `127.0.0.1:8765`.
2. `curl http://127.0.0.1:8765/health` → `{"status":"ok","model_loaded":false,...}` (no model yet).
3. From the tray app (or `curl -X POST http://127.0.0.1:8765/model/download`), download the model and confirm `/health` flips to `model_loaded:true`.
4. Dictate a short phrase and confirm a transcript comes back.
5. Check `dist\SunoFlowSidecar\` contains `DirectML.dll` (~18 MB), alongside `onnxruntime.dll` and `onnxruntime_pybind11_state.pyd`. There is no `onnxruntime_providers_directml.dll` to look for: unlike CUDA/TensorRT, the DirectML provider is linked into the core onnxruntime binary rather than shipped as a separate provider DLL, so only `DirectML.dll` and `onnxruntime_providers_shared.dll` appear next to it. If `DirectML.dll` is missing, the DirectML EP won't bind and inference falls back to CPU.
6. **SSL/model-download sanity:** with the sidecar frozen and running, trigger `POST /model/download` and confirm the model files start streaming from `huggingface.co`. If you see `SSL: CERTIFICATE_VERIFY_FAILED` or similar, the `certifi` `cacert.pem` data file was not collected — check `dist\SunoFlowSidecar\_internal\certifi\` for `cacert.pem`; if absent, the `collect_data_files("certifi")` line in the spec did not resolve for your wheel version and you need to add it explicitly.

If you hit a `ModuleNotFoundError` at runtime, add the missing module to `hiddenimports` in `sidecar.spec` and rebuild. If you hit "Failed to load provider library", `DirectML.dll` is missing from the dist folder — the manual DLL scan in the spec didn't catch it for your wheel version; add it explicitly.

## Deploying with the tray app

The C# tray app talks to the sidecar over `http://127.0.0.1:8765` and assumes the sidecar is already running. The intended install layout is:

```
%LOCALAPPDATA%\SunoFlow\
  sidecar\SunoFlowSidecar\        ← the frozen bundle (this build's output)
  model\                          ← downloaded on first run (~2.5 GB fp32 / ~0.67 GB int8)
  corrections.json                ← seeded from the bundle on first run
  app-debug.log                   ← tray app log
  preferences.json                ← tray app settings
```

The tray app finds the sidecar at `%LOCALAPPDATA%\SunoFlow\sidecar\
SunoFlowSidecar\SunoFlowSidecar.exe` and spawns + supervises it automatically
(via `SidecarSupervisor`): it starts the sidecar on launch and respawns it when
the 3-second `/health` poll fails (a 10-second cooldown prevents a crash loop).
The sidecar's stdout/stderr are teed into `%LOCALAPPDATA%\SunoFlow\sidecar.log`
for diagnosis. On tray-app quit the sidecar is intentionally left running (it's
an independent service — restarting the tray app shouldn't force a model
reload). Boot auto-start of the tray app itself is handled via an HKCU `Run`
entry toggled in Settings → General (see the app README). The sidecar's HTTP
contract is pinned in `docs/CONTRACT.md`.