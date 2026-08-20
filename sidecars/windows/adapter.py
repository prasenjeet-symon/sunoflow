"""Parakeet TDT 0.6B ONNX STT adapter for Windows.

Wraps the ``onnx-asr`` package (istupakov/onnx-asr) behind the platform-agnostic
``SttAdapter`` interface. ``onnx-asr`` owns the full pipeline — log-mel
preprocessor, Conformer encoder, TDT decoder/joint, and the TDT decoding loop —
all as a single ``load_model`` + ``recognize`` call on top of ONNX Runtime. The
only heavy dependency is ``onnxruntime-directml`` (the DirectML execution
provider), which serves NVIDIA / AMD / Intel GPUs alike via DirectX 12 — this is
why we picked ONNX Runtime over NeMo for the Windows track (NeMo would have been
NVIDIA-only). No PyTorch, NeMo, or FFmpeg is needed.

GPU is mandatory on Windows (no CPU-only support target); the adapter still
falls back to CPU if DirectML isn't available so the sidecar is at least
runnable on a dev box without a DX12 GPU — but production is GPU-only.

The download manager pulls the ONNX export of Parakeet TDT 0.6B v3 from
``istupakov/parakeet-tdt-0.6b-v3-onnx``. ``onnx-asr`` can download it itself via
huggingface_hub, but we manage the download ourselves so the dashboard gets
byte-level progress (the contract's ``/model/status`` fields) and so the model
lands in our stable, app-owned directory — mirroring the macOS MLX adapter.
Once all files are present, ``load()`` resolves the model offline
(``offline=True`` + ``path=MODEL_DIR``) so there's no startup network call.

See ``docs/CONTRACT.md`` for the HTTP contract and ``sidecars/shared/app.py``
for the routes this adapter plugs into.
"""
import os
import threading

from sidecars.shared.app import SttAdapter, create_app
from sidecars.shared.audio import wav_duration_seconds  # noqa: F401  (re-exported)

# --- onnx-asr (lazy import) ---------------------------------------------------
# ``onnx_asr`` imports ``onnxruntime`` at module load. We don't import it here so
# that ``import sidecars.windows.adapter`` works on any OS for tooling/tests;
# the real import happens in ``load()`` / ``transcribe_file()`` on the Windows
# host. ``onnxruntime`` itself exposes ``get_available_providers()`` which tells
# us whether DirectML is compiled in.

MODEL_ID = "nemo-parakeet-tdt-0.6b-v3"
HF_REPO = "istupakov/parakeet-tdt-0.6b-v3-onnx"

# --- Managed model directory ---------------------------------------------------
# %LOCALAPPDATA%/SunoFlow/model on Windows. Stable across reinstalls so a sidecar
# upgrade doesn't force a re-download. Override with SUNOFLOW_MODEL_DIR.
_DEFAULT_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "SunoFlow",
    "model",
)
MODEL_DIR = os.path.abspath(
    os.environ.get("SUNOFLOW_MODEL_DIR", _DEFAULT_DIR)
)

# Files that together make up a complete FP32 model snapshot. The encoder graph
# is split across encoder-model.onnx (graph) + encoder-model.onnx.data (weights,
# ~2.4 GB external data) — both MUST be present for the session to load.
# nemo128.onnx is the log-mel preprocessor graph. We pull the FP32 (non-int8)
# files for accuracy parity with the macOS MLX path; int8 is a later option.
MODEL_FILES = [
    "config.json",
    "encoder-model.onnx",
    "encoder-model.onnx.data",
    "decoder_joint-model.onnx",
    "nemo128.onnx",   # log-mel preprocessor
    "vocab.txt",
]
HF_BASE = f"https://huggingface.co/{HF_REPO}/resolve/main"


class ParakeetOnnxAdapter(SttAdapter):
    """Parakeet TDT 0.6B v3 ONNX engine + ONNX-export download manager."""

    def __init__(self):
        self.model = None
        self._dl_lock = threading.Lock()
        self._dl_state = {
            "active": False,
            "phase": "idle",        # idle | downloading | loading | done | error
            "current_file": "",
            "downloaded": 0,        # bytes downloaded so far for the current file
            "file_total": 0,        # total bytes for the current file
            "overall_done": 0,      # number of files finished
            "overall_total": len(MODEL_FILES),
            "error": "",
        }

    # --- SttAdapter: model lifecycle -------------------------------------------

    def is_loaded(self) -> bool:
        return self.model is not None

    def is_present(self) -> bool:
        """True if the managed model directory has every file we need."""
        return all(os.path.exists(os.path.join(MODEL_DIR, f)) for f in MODEL_FILES)

    def load(self) -> None:
        """Load the Parakeet ONNX model from disk.

        Resolves the model offline against ``MODEL_DIR`` so there's no startup
        network call once the files are present. Selects the DirectML EP when
        available (production: GPU), otherwise falls back to CPU (dev only).
        Soft-fails: on any error leaves ``self.model`` None so /transcribe
        returns empty rather than crashing the sidecar.
        """
        if not self.is_present():
            print(f"Model files missing in {MODEL_DIR}; cannot load.")
            return
        import onnx_asr
        import onnxruntime as rt

        providers = self._select_providers(rt)
        print(f"Loading ONNX model from {MODEL_DIR} (providers={providers}) ...")
        self.model = onnx_asr.load_model(
            MODEL_ID,
            path=MODEL_DIR,
            providers=providers,
        )
        print("Model loaded.")

    def transcribe_file(self, path: str) -> str:
        # onnx-asr's recognize() accepts a WAV file path directly and does its
        # own resampling to 16 kHz. Returns the transcript string.
        return self.model.recognize(path)

    # --- SttAdapter: download manager ------------------------------------------

    def start_download(self) -> dict:
        with self._dl_lock:
            if self._dl_state["active"]:
                return {"started": False, "reason": "already_running"}
        if self.is_present() and self.is_loaded():
            return {"started": False, "reason": "already_present"}
        threading.Thread(target=self._run_download, daemon=True).start()
        return {"started": True}

    # --- internals -------------------------------------------------------------

    def _select_providers(self, rt_module) -> list:
        """Pick the DirectML EP when compiled in, else CPU (dev fallback)."""
        available = list(rt_module.get_available_providers())
        if "DmlExecutionProvider" in available:
            return ["DmlExecutionProvider", "CPUExecutionProvider"]
        print("DirectML provider not available; falling back to CPU (dev only).")
        return ["CPUExecutionProvider"]

    def _download_file(self, url: str, dest: str) -> None:
        """Stream a single file to disk, updating _dl_state progress as bytes arrive."""
        import requests as _requests

        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".part"
        with _requests.get(url, stream=True, timeout=60) as r:
            r.raise_for_status()
            total = int(r.headers.get("Content-Length", 0))
            with self._dl_lock:
                self._dl_state["file_total"] = total
                self._dl_state["downloaded"] = 0
                self._dl_state["current_file"] = os.path.basename(dest)
            written = 0
            with open(tmp, "wb") as f:
                for chunk in r.iter_content(chunk_size=1 << 20):  # 1 MiB
                    if not chunk:
                        continue
                    f.write(chunk)
                    written += len(chunk)
                    with self._dl_lock:
                        self._dl_state["downloaded"] = written
        os.replace(tmp, dest)

    def _run_download(self) -> None:
        """Worker thread: fetch every model file, then load the model in-process."""
        try:
            os.makedirs(MODEL_DIR, exist_ok=True)
            with self._dl_lock:
                self._dl_state.update(
                    active=True, phase="downloading", overall_done=0,
                    error="", current_file="",
                )
            for i, fname in enumerate(MODEL_FILES):
                dest = os.path.join(MODEL_DIR, fname)
                if os.path.exists(dest):
                    # Already have this file (e.g. a resume). Skip but count it.
                    with self._dl_lock:
                        self._dl_state["overall_done"] = i + 1
                    continue
                self._download_file(f"{HF_BASE}/{fname}", dest)
                with self._dl_lock:
                    self._dl_state["overall_done"] = i + 1

            with self._dl_lock:
                self._dl_state.update(phase="loading", current_file="")
            self.load()
            with self._dl_lock:
                self._dl_state.update(phase="done", active=False)
        except Exception as exc:
            print(f"Model download failed: {exc}")
            with self._dl_lock:
                self._dl_state.update(phase="error", active=False, error=str(exc))

    def status_snapshot(self) -> dict:
        with self._dl_lock:
            snap = dict(self._dl_state)
        snap["model_dir"] = MODEL_DIR
        snap["model_id"] = HF_REPO
        return snap


def build_app(corrections_path: str | None = None) -> "object":
    """Construct the FastAPI app for the Windows ONNX sidecar.

    ``corrections_path`` defaults to ``corrections.json`` next to this file.
    """
    if corrections_path is None:
        corrections_path = os.path.join(os.path.dirname(__file__), "corrections.json")
    return create_app(ParakeetOnnxAdapter(), corrections_path)