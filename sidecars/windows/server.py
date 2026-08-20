"""Windows SunoFlow sidecar entry point.

Boots the shared FastAPI app with the ONNX Runtime (DirectML) STT adapter on
127.0.0.1:8765. All HTTP routes and platform-agnostic logic live in
``sidecars.shared``; this file only wires the ONNX adapter + ``corrections.json``
and runs uvicorn. See ``docs/CONTRACT.md`` for the HTTP contract.

Run on Windows::

    pip install onnxruntime-directml onnx-asr[hub] uvicorn requests
    python sidecars/windows/server.py
"""
import sys
from pathlib import Path

# When run from the repo (``python sidecars/windows/server.py``) the package
# parent isn't on sys.path by default — add the repo root so ``sidecars.*``
# resolves.
_REPO_ROOT = str(Path(__file__).resolve().parents[2])
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from sidecars.windows.adapter import build_app  # noqa: E402

app = build_app()

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8765)