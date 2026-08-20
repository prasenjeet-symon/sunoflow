# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the SunoFlow Windows sidecar (ONNX Runtime + DirectML).

Build (on a Windows box with a DirectX 12 GPU)::

    cd sidecars\\windows
    python -m venv .venv
    .venv\\Scripts\\activate
    python -m pip install -r requirements.txt pyinstaller
    pyinstaller --clean --noconfirm sidecar.spec
    -> dist\\SunoFlowSidecar\\SunoFlowSidecar.exe

Output is a **one-folder** bundle (``dist/SunoFlowSidecar/``). One-folder is
mandatory here: ``onnxruntime`` discovers its execution-provider DLLs by path
at runtime, and a one-file build extracts to a temp dir whose location is not
on ``PATH`` — that breaks provider loading. One-folder keeps every DLL next to
the exe, which is exactly where onnxruntime looks.

The Parakeet ONNX model (~2.5 GB) is NOT bundled. It is downloaded on first run
into ``%LOCALAPPDATA%/SunoFlow/model`` by the dashboard's Model tab (the
adapter's download manager). This keeps the installer small and lets users
skip the download until they need dictation.

What we collect explicitly:
  - onnxruntime      : every submodule + all native DLLs (providers, the
                       pybind state) + the DirectML DLLs that ship in the
                       onnxruntime-directml wheel. Without the manual DLL scan
                       PyInstaller's static analysis misses the DirectML
                       provider (loaded by name at runtime via ctypes).
  - onnx_asr         : the STT pipeline wrapper (preprocessor + decoder loop).
  - huggingface_hub  : onnx-asr's [hub] extra; used to resolve the model id to
                       a local path on first load even though we pass path=
                       (some code paths still import it eagerly).
  - uvicorn/starlette/fastapi/multipart : the web stack. These all use
                       dynamic/importlib imports for protocols, loops,
                       middleware, and the multipart form parser, so
                       collect_submodules is the only reliable way to catch
                       everything.

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

# The entry point lives next to this spec; the repo root (two levels up) is
# added to ``pathex`` so the ``sidecars`` package imports resolve at build time.
SPEC_DIR = Path(SPEC).resolve().parent                       # sidecars/windows
REPO_ROOT = str(SPEC_DIR.parents[1])                         # repo root
ENTRY = str(SPEC_DIR / "freeze_entry.py")
CORRECTIONS = str(SPEC_DIR / "corrections.json")

# --------------------------------------------------------------------------- #
# Hidden imports
# --------------------------------------------------------------------------- #
hiddenimports = []

# onnxruntime lazily loads provider backends and the C extension module that
# holds the pybind state; static analysis misses them.
hiddenimports += collect_submodules("onnxruntime")
hiddenimports += collect_submodules("onnxruntime.capi")
hiddenimports += [
    "onnxruntime.capi._pybind_state",
    "onnxruntime.capi.onnxruntime_pybind11_state",
]

# onnx-asr dynamically loads model/tokenizer classes.
hiddenimports += collect_submodules("onnx_asr")
hiddenimports += collect_submodules("huggingface_hub")

# Web stack — uvicorn loads protocol/loop implementations by name via the
# ``auto`` shims; starlette/fastapi lazy-load middleware; python-multipart is
# imported only when a Form()/File() route is hit.
hiddenimports += collect_submodules("uvicorn")
hiddenimports += collect_submodules("starlette")
hiddenimports += collect_submodules("fastapi")
hiddenimports += collect_submodules("pydantic")
hiddenimports += ["multipart"]

# Model-download path: adapter._download_file does a top-level ``import requests``
# (caught by static analysis), but requests' transitive submodules (urllib3,
# certifi, charset_normalizer, idna) are sometimes only reached via dynamic
# imports. huggingface_hub conditionally uses tqdm for progress bars and pulls
# in platformdirs/filelock; these are common first-build misses. Defensively
# collecting them costs nothing and avoids a runtime ImportError on first
# ``POST /model/download`` (HTTPS to huggingface.co) in the frozen bundle.
hiddenimports += collect_submodules("requests")
hiddenimports += collect_submodules("urllib3")
hiddenimports += [
    "tqdm",
    "platformdirs",
    "filelock",
    "charset_normalizer",
    "idna",
]

# --------------------------------------------------------------------------- #
# Data files + binaries
# --------------------------------------------------------------------------- #
datas = []
binaries = []

# onnxruntime: package data + every native library (core, providers shared,
# DirectML provider). collect_dynamic_libs finds the .pyd/.dll files; the
# manual scan below also picks up the DirectML DLLs shipped in the wheel root
# that collect_dynamic_libs sometimes classifies as data.
datas += collect_data_files("onnxruntime")
binaries += collect_dynamic_libs("onnxruntime")
try:
    import onnxruntime as _ort  # noqa: available at build time in the venv
    _ort_dir = os.path.dirname(_ort.__file__)
    for _fname in os.listdir(_ort_dir):
        if _fname.lower().endswith(".dll"):
            binaries.append((os.path.join(_ort_dir, _fname), "onnxruntime"))
    # The provider DLLs also live under capi/ on some wheel layouts.
    _capi = os.path.join(_ort_dir, "capi")
    if os.path.isdir(_capi):
        for _fname in os.listdir(_capi):
            if _fname.lower().endswith(".dll"):
                binaries.append((os.path.join(_capi, _fname), "onnxruntime/capi"))
except ImportError:
    pass

# onnx-asr assets (configs, tokenizer data).
datas += collect_data_files("onnx_asr")
datas += collect_data_files("huggingface_hub")

# certifi's cacert.pem is the CA bundle requests/urllib3 use for HTTPS. Without
# it the model download (HTTPS to huggingface.co) fails with SSL certificate
# errors inside the frozen bundle — PyInstaller's static analysis does NOT
# pick up this data file because certifi locates it via importlib.resources at
# runtime, so collect it explicitly.
datas += collect_data_files("certifi")

# Starlette/FastAPI ship a few non-Python assets.
datas += collect_data_files("starlette")
datas += collect_data_files("fastapi")

# Ship the empty corrections.json as a seed; freeze_entry.py copies it to a
# writable location in %LOCALAPPDATA% on first run.
if os.path.exists(CORRECTIONS):
    datas.append((CORRECTIONS, "."))

# --------------------------------------------------------------------------- #
# Analysis
# --------------------------------------------------------------------------- #
a = Analysis(
    [ENTRY],
    pathex=[REPO_ROOT, str(SPEC_DIR)],
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
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

# One-folder build (COLLECT). Keep the console so the sidecar's stdout is
# visible when launched from a terminal; the tray app hides the window anyway.
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="SunoFlowSidecar",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                       # UPX can corrupt onnxruntime DLLs.
    console=True,
    disable_windowed_traceback=False,
    # target_arch is macOS-only and ignored on Windows; the bundle is x64
    # because build.ps1 runs an x64 Python. Don't set it here.
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