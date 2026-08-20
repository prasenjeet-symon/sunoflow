"""Frozen sidecar entry point for PyInstaller (--onedir).

The dev entry point (``server.py``) adds the repo root to ``sys.path`` so the
``sidecars`` package resolves when run from a checkout. That trick does not
apply once frozen — PyInstaller bundles the package at build time via the
spec's ``pathex``. This file is what ``sidecar.spec`` points Analysis at.

It also fixes one thing freezing breaks: the corrections dictionary. The
adapter defaults ``corrections_path`` to ``corrections.json`` next to its own
``__file__``, which inside a frozen bundle is a read-only path (the bundle may
live under ``Program Files``). We resolve a *writable* copy in
``%LOCALAPPDATA%/SunoFlow/corrections.json`` and seed it from the bundled
``corrections.json`` on first run, so the sidecar can learn/persist
corrections just like the dev build.

Build::

    pyinstaller --clean --noconfirm sidecars/windows/sidecar.spec
    -> dist/SunoFlowSidecar/SunoFlowSidecar.exe
"""
import os
import shutil
import sys


def _bundle_dir() -> str:
    """Where PyInstaller placed our data files.

    ``--onedir``: the directory containing the exe (``os.path.dirname(sys.executable)``).
    ``--onefile``: the temp-extraction dir (``sys._MEIPASS``).
    Not frozen: this file's own dir (dev fallback).
    """
    if getattr(sys, "frozen", False):
        return getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def _writable_corrections_path() -> str:
    """A writable corrections.json in %LOCALAPPDATA%/SunoFlow, seeded on first run."""
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    user_dir = os.path.join(base, "SunoFlow")
    os.makedirs(user_dir, exist_ok=True)
    user_file = os.path.join(user_dir, "corrections.json")
    if not os.path.exists(user_file):
        bundled = os.path.join(_bundle_dir(), "corrections.json")
        if os.path.exists(bundled):
            shutil.copy2(bundled, user_file)
        else:
            with open(user_file, "w", encoding="utf-8") as f:
                f.write("{}")
    return user_file


def main() -> None:
    # Imported here (not at module top) so a misconfigured frozen env fails with
    # a clear traceback rather than a bootloader-level import error.
    from sidecars.windows.adapter import build_app
    import uvicorn

    app = build_app(corrections_path=_writable_corrections_path())
    uvicorn.run(app, host="127.0.0.1", port=8765)


if __name__ == "__main__":
    main()