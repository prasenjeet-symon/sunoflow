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
import array
import math
import os
import re
import shutil
import tempfile
import threading
import wave

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

# Roughly what MODEL_FILES weigh once unpacked on disk (the encoder weights are
# ~2.4 GB of it), plus headroom. Checked before the first byte is fetched:
# discovering a full disk 2.3 GB into a 2.5 GB download wastes the download and
# leaves a half-written model behind.
MODEL_BYTES_TOTAL = 2_700_000_000
DISK_HEADROOM_BYTES = 300_000_000

# Length of the clip pushed through the model to prove it can actually run.
# Comfortably longer than MIN_AUDIO_SECONDS and than the encoder's subsampling
# window, so the pass exercises the real path rather than an edge case.
SMOKE_SECONDS = 1.0


class ParakeetOnnxAdapter(SttAdapter):
    """Parakeet TDT 0.6B v3 ONNX engine + ONNX-export download manager."""

    def __init__(self):
        self.model = None
        # The compute path the loaded model was actually verified on, so the
        # dashboard can stop asserting "GPU" on a box that quietly fell back.
        self._runtime = ""
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
        """True only once a real forward pass has succeeded — see :meth:`load`."""
        return self.model is not None

    def is_present(self) -> bool:
        """True if the managed model directory has every file we need."""
        return all(os.path.exists(os.path.join(MODEL_DIR, f)) for f in MODEL_FILES)

    def runtime_label(self) -> str:
        return self._runtime

    def load(self) -> None:
        """Load the Parakeet ONNX model from disk and prove it can run.

        Resolves the model offline against ``MODEL_DIR`` so there's no startup
        network call once the files are present. Selects the DirectML EP when
        available (production: GPU), otherwise falls back to CPU (dev only).

        The model is only published to ``self.model`` after a real clip has been
        through it. Building the sessions proves the graphs parsed and nothing
        more: a DirectML device that is absent, reset or out of memory, and
        external weights truncated by a full disk, all construct cleanly and
        fail on the first ``Run``. Such a model used to report itself ready,
        answer every dictation with an empty transcript (the shared app
        soft-fails inference to empty) and say nothing about why. The pass
        doubles as a warmup, so the first real dictation no longer pays for
        kernel compilation.

        Leaves ``self.model`` None and ``self.load_error`` set on any failure,
        then re-raises — /transcribe returns empty rather than crashing the
        sidecar, and the dashboard has words for what went wrong.
        """
        if not self.is_present():
            # Not an error: nothing has been downloaded yet. Saying so here
            # would put a failure on a dashboard whose real state is "missing".
            print(f"Model files missing in {MODEL_DIR}; cannot load.")
            return
        import onnx_asr
        import onnxruntime as rt

        providers = self._select_providers(rt)
        runtime = ("GPU (DirectML)" if providers[0] == "DmlExecutionProvider" else "CPU")
        print(f"Loading ONNX model from {MODEL_DIR} (providers={providers}) ...")
        try:
            model = onnx_asr.load_model(
                MODEL_ID,
                path=MODEL_DIR,
                providers=providers,
            )
            self._verify_runnable(model)
        except Exception as exc:
            self.model = None
            self._runtime = ""
            self.load_error = re.sub(r"https?://\S+", "[model URL]", str(exc)).strip() \
                or exc.__class__.__name__
            print(f"Model failed to load: {exc}")
            raise
        self.model = model
        self._runtime = runtime
        self.load_error = ""
        print(f"Model loaded and verified on {runtime}.")

    def _verify_runnable(self, model) -> None:
        """Push one short clip through ``model``, raising if it cannot run it.

        A quiet tone rather than digital silence: an all-zero mel can take a
        degenerate path through the decoder, which would prove less than a real
        utterance does. The transcript is discarded — what is being tested is
        that inference completes at all.
        """
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        try:
            frames = int(16000 * SMOKE_SECONDS)
            samples = array.array(
                "h",
                (int(2000 * math.sin(2 * math.pi * 220 * i / 16000)) for i in range(frames)),
            )
            with wave.open(path, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(16000)
                w.writeframes(samples.tobytes())
            model.recognize(path)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

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
            shortfall = self._disk_shortfall()
            if shortfall:
                # Refused before the first byte. Filling the disk mid-download
                # does not just waste the transfer: it truncates the external
                # weights file, which then loads cleanly and fails on the first
                # inference — the exact failure this whole path exists to avoid.
                print(f"Refusing model download: {shortfall}")
                with self._dl_lock:
                    self._dl_state.update(phase="error", active=False, error=shortfall)
                return
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

        except Exception as exc:
            print(f"Model download failed: {exc}")
            # Strip any URL from the surfaced error so the upstream model
            # source isn't leaked to the client UI; the full exception is kept in the log.
            safe = re.sub(r"https?://\S+", "[download URL]", str(exc))
            with self._dl_lock:
                self._dl_state.update(phase="error", active=False, error=safe)
            return

        # Loading is a separate failure from downloading, and saying so matters:
        # by this point 2.5 GB is on disk, and reporting "download failed" would
        # invite the user to fetch all of it again to fix something the download
        # had nothing to do with.
        try:
            with self._dl_lock:
                self._dl_state.update(phase="loading", current_file="")
            self.load()
            with self._dl_lock:
                self._dl_state.update(phase="done", active=False)
        except Exception as exc:
            print(f"Model downloaded but failed to load: {exc}")
            safe = re.sub(r"https?://\S+", "[download URL]", str(exc))
            with self._dl_lock:
                self._dl_state.update(
                    phase="error", active=False,
                    error=f"The model downloaded, but the engine could not start it: {safe}",
                )

    def status_snapshot(self) -> dict:
        with self._dl_lock:
            snap = dict(self._dl_state)
        snap["model_dir"] = MODEL_DIR
        snap["model_id"] = HF_REPO
        return snap

    def _disk_shortfall(self) -> str:
        """The reason there isn't room for the model, or "" when there is.

        Only the files still missing are counted — a resumed download has most
        of the 2.5 GB on disk already and should not be refused for space it is
        not about to use.
        """
        try:
            have = 0
            for fname in MODEL_FILES:
                path = os.path.join(MODEL_DIR, fname)
                if os.path.exists(path):
                    have += os.path.getsize(path)
            needed = max(MODEL_BYTES_TOTAL - have, 0) + DISK_HEADROOM_BYTES
            free = shutil.disk_usage(MODEL_DIR).free
            if free >= needed:
                return ""
            drive = os.path.splitdrive(MODEL_DIR)[0] or MODEL_DIR
            return (f"Not enough disk space: the speech model needs about "
                    f"{_gb(needed)} free on {drive} and there is {_gb(free)}.")
        except OSError as exc:
            # An unreadable drive is not a reason to block a download that might
            # well succeed; let the transfer itself report the real problem.
            print(f"Could not check free disk space: {exc}")
            return ""


def _gb(n: int) -> str:
    """Bytes as a short GB string for a message a user will read."""
    return f"{n / 1_000_000_000:.1f} GB"


def build_app(corrections_path: str | None = None) -> "object":
    """Construct the FastAPI app for the Windows ONNX sidecar.

    ``corrections_path`` defaults to ``corrections.json`` next to this file.
    """
    if corrections_path is None:
        corrections_path = os.path.join(os.path.dirname(__file__), "corrections.json")
    return create_app(ParakeetOnnxAdapter(), corrections_path)