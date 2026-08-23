# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the SunoFlow macOS sidecar (parakeet-mlx / MLX).

Build (on an Apple-Silicon Mac)::

    cd sidecar
    ./build.sh
    -> dist/SunoFlowSidecar/SunoFlowSidecar

Output is a **one-folder** bundle (``dist/SunoFlowSidecar/``). One-folder is
mandatory here for two reasons:

1. MLX loads its Metal shader library (``mlx.metallib``, 130 MB) and native
   dylibs (``libmlx.dylib``, ``libjaccl.dylib``) by path at runtime via
   ``ctypes``/``dlopen``. A ``--onefile`` build extracts to a temp dir whose
   location is not stable; one-folder keeps the dylibs next to the exe, which
   is exactly where MLX looks.
2. ``numba``/``llvmlite`` JIT-compile against ``libllvmlite.dylib`` and a set
   of C extension modules that are discovered dynamically; one-folder avoids
   the extraction-timing races that onefile is prone to with JIT toolchains.

The Parakeet MLX model (~2.4 GB) is NOT bundled. It is downloaded on first run
into ``~/Library/Application Support/SunoFlow/model`` from the dashboard's
Model tab (``POST /model/download``). This keeps the installer small and lets
users skip the big download until they need dictation.

What we collect explicitly:
  - mlx / mlx-metal : every submodule + the native dylibs (``libmlx.dylib``,
                       ``libjaccl.dylib``) and the Metal shader library
                       (``mlx.metallib``). ``collect_dynamic_libs`` catches the
                       dylibs; the manual scan below forces the ``.metallib``
                       (a data-classified asset) into ``datas`` so it ships.
  - parakeet_mlx    : the STT model wrapper (pure Python; submodules collected
                      so the conformer/attention/tokenizer modules bundle).
  - numba/llvmlite  : the JIT stack. numba lazily registers dispatchers and
                      C extensions; collect_submodules is the only reliable
                      way to catch them. llvmlite ships ``libllvmlite.dylib``.
  - numpy/scipy/librosa/soundfile : the audio/numerics stack. scipy ships
                      Fortran dylibs under ``.dylibs/``; soundfile ships
                      ``libsndfile`` under ``_soundfile_data/``.
  - uvicorn/starlette/fastapi/multipart : the web stack. These all use
                      dynamic/importlib imports for protocols, loops,
                      middleware, and the multipart form parser, so
                      collect_submodules is the only reliable way to catch
                      everything.
  - requests/urllib3/certifi : the model-download path POSTs to the cleanup
                      gateway and pulls model files from huggingface.co over
                      HTTPS; certifi's ``cacert.pem`` must ship as data or the
                      download fails with SSL errors in the frozen bundle.

See ``freeze_entry.py`` for the frozen-aware entry point and the writable
``corrections.json`` handling, and ``docs/CONTRACT.md`` for the HTTP contract.
"""
import os
import sys
from pathlib import Path

from PyInstaller.utils.hooks import (
    collect_data_files,
    collect_dynamic_libs,
    collect_submodules,
)

block_cipher = None

# The entry point + spec live in sidecar/; that directory is added to pathex so
# ``server.py`` (imported by freeze_entry.py) resolves at build time.
SPEC_DIR = Path(SPEC).resolve().parent                       # sidecar/
ENTRY = str(SPEC_DIR / "freeze_entry.py")
CORRECTIONS = str(SPEC_DIR / "corrections.json")

# --------------------------------------------------------------------------- #
# Hidden imports
# --------------------------------------------------------------------------- #
hiddenimports = []

# Web stack — uvicorn loads protocol/loop implementations by name via the
# ``auto`` shims; starlette/fastapi lazy-load middleware; python-multipart is
# imported only when a Form()/File() route is hit (the /transcribe upload).
hiddenimports += collect_submodules("uvicorn")
hiddenimports += collect_submodules("starlette")
hiddenimports += collect_submodules("fastapi")
hiddenimports += collect_submodules("pydantic")
hiddenimports += ["multipart"]

# MLX — the C extension (mlx.core) and the native Metal dylibs. The .so is a
# normal extension module that static analysis finds, but the dylibs it loads
# via dlopen and the metallib shader cache are not.
hiddenimports += collect_submodules("mlx")
hiddenimports += collect_submodules("parakeet_mlx")

# numba/llvmlite JIT stack — numba registers C extension dispatchers and
# helper modules dynamically; llvmlite binds to libllvmlite.dylib.
hiddenimports += collect_submodules("numba")
hiddenimports += collect_submodules("llvmlite")
hiddenimports += collect_submodules("numba.cloudpickle")

# Numerics + audio. numpy/scipy ship Fortran/OpenMP dylibs under .dylibs/;
# librosa/soundfile/soxr are reached via dynamic imports from parakeet_mlx's
# audio path.
hiddenimports += collect_submodules("numpy")
hiddenimports += collect_submodules("scipy")
hiddenimports += collect_submodules("librosa")
hiddenimports += ["soxr", "audioread", "soundfile"]

# Model-download + cleanup-gateway path: requests pulls model files from
# huggingface.co over HTTPS; urllib3/charset_normalizer/idna are sometimes
# only reached via dynamic imports. certifi locates its CA bundle via
# importlib.resources, so its data file must be collected explicitly (below).
hiddenimports += collect_submodules("requests")
hiddenimports += collect_submodules("urllib3")
hiddenimports += collect_submodules("huggingface_hub")
hiddenimports += [
    "tqdm",
    "platformdirs",
    "filelock",
    "charset_normalizer",
    "idna",
    "certifi",
    "ssl",
    "http.client",
]

# --------------------------------------------------------------------------- #
# Data files + binaries
# --------------------------------------------------------------------------- #
datas = []
binaries = []

# MLX native libs (libmlx.dylib, libjaccl.dylib) + package data.
datas += collect_data_files("mlx")
binaries += collect_dynamic_libs("mlx")
# The Metal shader library (mlx.metallib, ~130 MB) lives under mlx/lib/.
# collect_data_files/collect_dynamic_libs sometimes classify it as neither;
# force it into datas via a manual scan.
try:
    import mlx as _mlx  # noqa: available at build time in the venv
    _mlx_dir = os.path.dirname(os.path.dirname(_mlx.__file__) or str(_mlx.__path__[0]))
    _mlx_lib = os.path.join(_mlx_dir, "mlx", "lib")
    if os.path.isdir(_mlx_lib):
        for _fname in os.listdir(_mlx_lib):
            if _fname.endswith((".metallib", ".dylib")):
                datas.append((os.path.join(_mlx_lib, _fname), "mlx/lib"))
except Exception:
    pass

# parakeet_mlx has no native libs, but collect its package data if any.
datas += collect_data_files("parakeet_mlx")

# llvmlite native lib (libllvmlite.dylib).
binaries += collect_dynamic_libs("llvmlite")

# scipy ships Fortran/OpenMP runtime dylibs under .dylibs/.
binaries += collect_dynamic_libs("scipy")
datas += collect_data_files("scipy")

# numpy — collect_data_files for any packaged data; some wheels ship .dylibs.
datas += collect_data_files("numpy")
binaries += collect_dynamic_libs("numpy")

# librosa/soundfile package data.
datas += collect_data_files("librosa")
datas += collect_data_files("soundfile")
# libsndfile ships under _soundfile_data/ as a dylib — collect_dynamic_libs
# covers the soundfile package, but the _soundfile_data top-level package is
# separate; collect it as data so the bundled libsndfile dylib is present.
datas += collect_data_files("_soundfile_data")

# certifi's cacert.pem is the CA bundle requests/urllib3 use for HTTPS. Without
# it the model download (HTTPS to huggingface.co) fails with SSL certificate
# errors inside the frozen bundle — PyInstaller's static analysis does NOT
# pick up this data file because certifi locates it via importlib.resources at
# runtime, so collect it explicitly.
datas += collect_data_files("certifi")

# Starlette/FastAPI ship a few non-Python assets.
datas += collect_data_files("starlette")
datas += collect_data_files("fastapi")

# Ship the corrections.json as a seed; freeze_entry.py copies it to a writable
# location in ~/Library/Application Support/SunoFlow/ on first run.
if os.path.exists(CORRECTIONS):
    datas.append((CORRECTIONS, "."))

# --------------------------------------------------------------------------- #
# Analysis
# --------------------------------------------------------------------------- #
a = Analysis(
    [ENTRY],
    pathex=[str(SPEC_DIR)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Slim the bundle: these are never used by the sidecar.
        "tkinter",
        "matplotlib",
        "pytest",
        "tests",
        "IPython",
        "jupyter",
        "notebook",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

# One-folder build (COLLECT). No console window for a shipped app — the app's
# SidecarSupervisor tees stdout/stderr into ~/Library/Logs/SunoFlow/sidecar.log
# anyway, and a popping Terminal window on launch is bad UX.
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="SunoFlowSidecar",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                       # UPX can corrupt MLX/numba dylibs.
    console=False,
    disable_windowed_traceback=False,
    target_arch="arm64",             # Apple Silicon only — MLX is arm64-only.
    icon=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="SunoFlowSidecar",
)