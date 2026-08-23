"""Frozen sidecar entry point for PyInstaller (--onedir, macOS).

The dev entry point (``server.py``) lives next to ``corrections.json`` in the
repo and resolves the corrections path via ``os.path.dirname(__file__)``. That
path is **read-only** inside a frozen bundle shipped inside ``SunoFlow.app`` —
the app bundle is code-signed, and even if it weren't, a per-user correction
dictionary must persist across app upgrades in a stable, user-writable
location. This entry point resolves a writable ``corrections.json`` in
``~/Library/Application Support/SunoFlow/`` (seeding it from the bundled copy on
first run) and points the sidecar at it via the ``SUNOFLOW_CORRECTIONS_PATH``
env var that ``server.py`` now honors.

The model directory (``~/Library/Application Support/SunoFlow/model``) is
already user-writable by default in ``server.py``, so no override is needed for
it; only the corrections dictionary lives next to ``__file__`` and needs fixing.

Build::

    cd sidecar && ./build.sh
    -> dist/SunoFlowSidecar/SunoFlowSidecar
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
    """A writable corrections.json in ~/Library/Application Support/SunoFlow.

    Seeded from the bundled ``corrections.json`` (shipped as a spec data file)
    on first run; created empty if the seed is absent. Mirrors the Windows
    ``freeze_entry.py`` pattern.
    """
    home = os.path.expanduser("~")
    base = os.environ.get(
        "XDG_DATA_HOME",
        os.path.join(home, "Library", "Application Support"),
    )
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
    import uvicorn

    # Point server.py at the writable corrections dictionary before it imports
    # and reads CORRECTIONS_PATH at module load time.
    os.environ["SUNOFLOW_CORRECTIONS_PATH"] = _writable_corrections_path()

    import server  # noqa: E402  — imports after the env var is set

    uvicorn.run(server.app, host="127.0.0.1", port=8765)


if __name__ == "__main__":
    main()