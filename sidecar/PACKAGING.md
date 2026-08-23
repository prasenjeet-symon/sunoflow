# macOS sidecar — PyInstaller packaging

This freezes the SunoFlow macOS sidecar (FastAPI + parakeet-mlx / MLX) into a
self-contained one-folder bundle the end user can run without installing Python
or any pip packages.

> You must build on an **Apple-Silicon Mac** (M-chip). MLX is arm64-only — the
> spec pins `target_arch="arm64"` and the MLX/Metal dylibs are arm64. Intel Macs
> are not supported (see MEMORY.md: v1 launch is Apple-Silicon only).

## Quick build

```bash
cd sidecar
./build.sh
# → dist/SunoFlowSidecar/SunoFlowSidecar
```

`build.sh` creates a clean build venv (`.venv-build`), installs `requirements.txt`
+ PyInstaller, and runs the spec. The dev `.venv` is left untouched.

## Files

| File | Purpose |
|---|---|
| `freeze_entry.py` | Frozen-aware entry point. Resolves a **writable** `corrections.json` in `~/Library/Application Support/SunoFlow/` (the bundle dir is read-only inside a signed `.app`), seeds it from the bundled copy on first run, then boots uvicorn. Sets `SUNOFLOW_CORRECTIONS_PATH` before importing `server.py`, which honors it instead of its default `__file__`-relative path. |
| `sidecar.spec` | PyInstaller spec. Collects mlx/parakeet_mlx/numba/llvmlite/numpy/scipy/librosa submodules + the native dylibs (libmlx.dylib, libjaccl.dylib, libllvmlite.dylib, scipy's Fortran dylibs, libsndfile) and the Metal shader library (mlx.metallib), plus the uvicorn/starlette/fastapi/multipart web stack. |
| `build.sh` | One-command build script (venv → install → freeze). |

## Why one-folder, not one-file

1. MLX loads its Metal shader library (`mlx.metallib`, 130 MB) and native dylibs
   (`libmlx.dylib`, `libjaccl.dylib`) by path at runtime via `dlopen`. A
   `--onefile` build extracts to a temp dir that is not on a stable path; the
   dylibs may not be found. One-folder keeps every dylib next to the exe, which
   is exactly where MLX looks.
2. `numba`/`llvmlite` JIT-compile against `libllvmlite.dylib` and a set of C
   extension modules discovered dynamically; one-folder avoids the
   extraction-timing races that onefile is prone to with JIT toolchains.

`upx=False` for the same reason — UPX can corrupt MLX/numba dylibs.

## What is and isn't bundled

**Bundled:** the Python interpreter, all pip deps (mlx, mlx-metal, parakeet-mlx,
numba, llvmlite, numpy, scipy, librosa, soundfile, fastapi, uvicorn, starlette,
requests, huggingface_hub, pydantic, python-multipart), the native dylibs
(libmlx.dylib, libjaccl.dylib, libllvmlite.dylib, scipy's Fortran/OpenMP dylibs,
libsndfile), the Metal shader library (mlx.metallib), and a seed
`corrections.json`.

**Not bundled:** the Parakeet MLX model (~2.4 GB). The user downloads it on
first run from the menu-bar app's **Settings → Model** tab (or
`POST /model/download`). It lands in `~/Library/Application Support/SunoFlow/model`,
which is stable across sidecar upgrades so a reinstall doesn't force a
re-download. This keeps the installer small and lets users defer the big
download.

## Correctness notes

- **`mlx.metallib`** (the Metal shader cache, ~130 MB) lives under `mlx/lib/`.
  PyInstaller's `collect_data_files`/`collect_dynamic_libs` sometimes classify it
  as neither; the spec's manual scan of `mlx/lib/` forces it into `datas` so it
  ships. Without it, MLX can't compile Metal kernels and inference fails.
- **`numba.cloudpickle`** is vendored *inside* the `numba` package (not a
  top-level `cloudpickle`); it's collected explicitly so JIT'd functions
  pickle/unpickle correctly.
- **`_soundfile_data`** ships `libsndfile_arm64.dylib` under a top-level package
  separate from `soundfile`; it's collected as data so the bundled libsndfile
  dylib is present for WAV I/O.
- **`scipy/.dylibs/`** holds the Fortran/OpenMP runtime dylibs (libgfortran,
  libquadmath, libgcc_s); `collect_dynamic_libs("scipy")` picks these up.
- **`python-multipart`** imports as `multipart`. It's only imported when a
  `Form()`/`File()` route is hit (the `/transcribe` upload), so PyInstaller's
  static analysis misses it — it's listed explicitly.
- **`certifi` data file (`cacert.pem`)** is collected explicitly. Without it,
  the model download (`POST /model/download` → HTTPS to `huggingface.co`) fails
  with SSL certificate errors in the frozen bundle, because PyInstaller's
  static analysis does not pick up the data file certifi locates via
  `importlib.resources` at runtime.

## Verifying the bundle

After building, before shipping:

1. Run `dist/SunoFlowSidecar/SunoFlowSidecar` from a terminal. You should see
   uvicorn start on `127.0.0.1:8765` (stdout — there is no console window when
   launched by the app).
2. `curl http://127.0.0.1:8765/health` → `{"status":"ok","model_loaded":false,...}`
   (no model yet).
3. From the menu-bar app (or `curl -X POST http://127.0.0.1:8765/model/download`),
   download the model and confirm `/health` flips to `model_loaded:true`.
4. Dictate a short phrase and confirm a transcript comes back.
5. Check `dist/SunoFlowSidecar/` (and its `_internal/`) contains `libmlx.dylib`
   and `mlx.metallib`. If they're missing, MLX can't initialize Metal.
6. **SSL/model-download sanity:** with the sidecar frozen and running, trigger
   `POST /model/download` and confirm the model files start streaming from
   `huggingface.co`. If you see `SSL: CERTIFICATE_VERIFY_FAILED` or similar, the
   `certifi` `cacert.pem` data file was not collected — check
   `dist/SunoFlowSidecar/_internal/certifi/` for `cacert.pem`; if absent, the
   `collect_data_files("certifi")` line in the spec did not resolve for your
   wheel version and you need to add it explicitly.

If you hit a `ModuleNotFoundError` at runtime, add the missing module to
`hiddenimports` in `sidecar.spec` and rebuild. If MLX fails to load a dylib or
the metallib, the manual scan in the spec didn't catch it for your wheel
version; add it explicitly to `datas`/`binaries`.

## Deploying with the app

The Swift menu-bar app talks to the sidecar over `http://127.0.0.1:8765` and
spawns + supervises the frozen binary itself via `SidecarSupervisor.swift` —
there is no launchd plist for the sidecar in a distributed build. The intended
install layout is:

```
SunoFlow.app/Contents/
  MacOS/SunoFlow                      ← the Swift app
  Resources/
    sidecar/SunoFlowSidecar/          ← the frozen bundle (this build's output)
      SunoFlowSidecar                 ← the executable
      _internal/                      ← dylibs + datas + metallib
    Info.plist, AppIcon.icns
~/Library/Application Support/SunoFlow/
  model/                              ← downloaded on first run (~2.4 GB)
  corrections.json                    ← seeded from the bundle on first run
~/Library/Logs/SunoFlow/
  sidecar.log                         ← sidecar stdout/stderr (teed by the app)
```

`SidecarSupervisor` starts the sidecar on app launch and respawns it when the
3-second `/health` poll fails (a 10-second cooldown prevents a crash loop). On
app quit the sidecar is intentionally left running (it's an independent service
— restarting the app shouldn't force a model reload). The sidecar's HTTP
contract is pinned in `docs/CONTRACT.md`.