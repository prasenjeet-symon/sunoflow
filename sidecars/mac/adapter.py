"""Parakeet-MLX STT adapter for macOS (Apple Silicon).

Wraps the parakeet-mlx runtime behind the platform-agnostic ``SttAdapter``
interface. Owns the model global, the lazy MLX import, the on-disk model
directory, and the background download manager (file manifest + HuggingFace
source URLs are specific to the MLX snapshot).
"""
import os
import threading

import parakeet_mlx

from sidecars.shared.audio import wav_duration_seconds  # noqa: F401  (re-exported for convenience)
from sidecars.shared.app import SttAdapter, create_app

MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"

# --- Managed model directory ---------------------------------------------------
# For distribution the app ships WITHOUT the model bundled. The user downloads
# Parakeet on first run from the dashboard. Weights land in a stable, app-owned
# directory (~/Library/Application Support/SunoFlow/model) so a sidecar upgrade
# or reinstall doesn't force a re-download. parakeet_mlx.from_pretrained accepts
# a local directory path, so once the files are present we load straight from
# disk with no HuggingFace network call at startup.
MODEL_DIR = os.path.expanduser(
    os.environ.get(
        "SUNOFLOW_MODEL_DIR",
        "~/Library/Application Support/SunoFlow/model",
    )
)
# Files that together make up a complete model snapshot.
MODEL_FILES = [
    "config.json",
    "model.safetensors",
    "tokenizer.model",
    "tokenizer.vocab",
    "vocab.txt",
]
HF_BASE = "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main"


class ParakeetMlxAdapter(SttAdapter):
    """parakeet-mlx STT engine + MLX-snapshot download manager."""

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
        """Load the Parakeet model from disk when available, else from HF cache."""
        if self._local_model_complete():
            print(f"Loading model from {MODEL_DIR} ...")
            self.model = parakeet_mlx.from_pretrained(MODEL_DIR)
            print("Model loaded from managed directory.")
        else:
            # Fall back to the HuggingFace cache for existing installs that
            # haven't migrated to the managed directory yet. This keeps dev
            # setups working.
            print(f"Managed model not found; loading {MODEL_ID} from HF cache ...")
            self.model = parakeet_mlx.from_pretrained(MODEL_ID)
            print("Model loaded from HF cache.")

    def transcribe_file(self, path: str) -> str:
        # MLX's default stream is thread-local, so transcribe must run on the
        # same thread the model was loaded on (the event loop thread), not a
        # threadpool worker. The shared app runs this via run_in_threadpool for
        # the cleanup step, but transcribe itself is called inline on the loop
        # thread — see the note in the shared app's transcribe route. (parakeet-
        # mlx's transcribe is synchronous and fast enough to block briefly.)
        return self.model.transcribe(path).text

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

    def _local_model_complete(self) -> bool:
        return all(os.path.exists(os.path.join(MODEL_DIR, f)) for f in MODEL_FILES)

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

    def status_snapshot(self) -> dict:  # noqa: F811  (include display fields)
        with self._dl_lock:
            snap = dict(self._dl_state)
        snap["model_dir"] = MODEL_DIR
        snap["model_id"] = MODEL_ID
        return snap


def build_app(corrections_path: str | None = None) -> "object":
    """Construct the FastAPI app for the macOS parakeet-mlx sidecar.

    ``corrections_path`` defaults to ``corrections.json`` next to this file.
    """
    if corrections_path is None:
        corrections_path = os.path.join(os.path.dirname(__file__), "corrections.json")
    return create_app(ParakeetMlxAdapter(), corrections_path)