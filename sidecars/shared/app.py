"""FastAPI app factory + all HTTP routes — the shared sidecar skeleton.

Every sidecar (macOS parakeet-mlx, Windows onnxruntime-directml) implements the
``SttAdapter`` interface and calls ``create_app(adapter, corrections_path)``.
The HTTP contract is documented in ``docs/CONTRACT.md`` and MUST be identical
across platforms.

What stays platform-specific (lives in the adapter, NOT here):
  - model loading, inference, and the model's on-disk location
  - the model download manager (file manifest + source URLs differ per platform)
"""
import os
import tempfile
from collections import deque
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, Query, UploadFile
from starlette.concurrency import run_in_threadpool

from sidecars.shared.audio import MIN_AUDIO_SECONDS, wav_duration_seconds
from sidecars.shared.cleanup import clean_with_gateway
from sidecars.shared.corrections import Corrections

# Option A: keep the last few cleaned dictations so the model has continuity.
RECENT_HISTORY_N = 3


class SttAdapter:
    """Interface every platform's STT engine implements.

    The shared app calls only these methods; it never imports a model library
    or touches the on-disk model directory directly.
    """

    def is_loaded(self) -> bool:
        """True iff the STT model is resident in memory and ready to transcribe."""
        raise NotImplementedError

    def is_present(self) -> bool:
        """True iff all model files exist on disk (may be present but unloaded)."""
        raise NotImplementedError

    def load(self) -> None:
        """Load the model into memory. Called at startup and after a download.

        Must be idempotent and must set whatever state ``is_loaded`` reads.
        Soft-fail: on error, leave the model unloaded (the app still serves
        /health and /model/status; /transcribe returns empty).
        """
        raise NotImplementedError

    def transcribe_file(self, path: str) -> str:
        """Run inference on a WAV path; return the transcript text (stripped).

        Must raise on failure — the shared app catches and soft-fails to empty.
        """
        raise NotImplementedError

    def status_snapshot(self) -> dict:
        """Download/progress state for ``GET /model/status``.

        Return a dict with at least: ``active, phase, current_file, downloaded,
        file_total, overall_done, overall_total, error, model_dir, model_id``.
        See docs/CONTRACT.md §model-status for the exact fields the client reads.
        """
        raise NotImplementedError

    def start_download(self) -> dict:
        """Kick off a background model download. ``POST /model/download``.

        Return ``{"started": bool, "reason": str?}``. Idempotent: a no-op if a
        download is already running or the model is already present and loaded.
        When the download completes, the adapter MUST load the model in-process
        (no sidecar restart needed).
        """
        raise NotImplementedError


def create_app(adapter: SttAdapter, corrections_path: str) -> FastAPI:
    """Build the FastAPI app with all routes wired to ``adapter`` and the
    corrections dictionary at ``corrections_path``.
    """
    corrections = Corrections(corrections_path)
    recent_transcripts: "deque[str]" = deque(maxlen=RECENT_HISTORY_N)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        try:
            adapter.load()
        except Exception as exc:
            # If the model can't be loaded (e.g. nothing in the managed dir AND
            # the HF cache is empty / offline), don't crash the whole sidecar —
            # the user can trigger a download from the dashboard and we'll load
            # on demand.
            print(f"Could not load model at startup: {exc}")
        yield

    app = FastAPI(lifespan=lifespan)

    @app.get("/health")
    def health():
        return {
            "status": "ok",
            "model_loaded": adapter.is_loaded(),
            "model_present": adapter.is_present(),
        }

    @app.post("/transcribe")
    async def transcribe(
        file: UploadFile = File(...),
        cleanup: bool = Query(True),
        context: str = Form(""),
        screen: str = Form(""),
    ):
        fd, tmp_path = tempfile.mkstemp(suffix=".wav")
        try:
            with os.fdopen(fd, "wb") as tmp:
                tmp.write(await file.read())

            # STT engines underflow on empty/too-short audio: the mel length goes
            # negative and wraps to a huge unsigned value, so inference tries to
            # allocate ~2**64 bytes and the whole request 500s. Skip clips that
            # are too short to contain speech (accidental taps, a glitchy first
            # record right after boot) and return an empty transcript instead.
            duration = wav_duration_seconds(tmp_path)
            if duration is None or duration < MIN_AUDIO_SECONDS:
                print(f"Skipping transcription: audio too short ({duration} s)")
                return {"raw": "", "cleaned": ""}

            if not adapter.is_loaded():
                # The sidecar is up but the STT model isn't loaded yet (user
                # hasn't downloaded it, or the download is still running).
                # Surface this as a soft empty result rather than crashing.
                print("Transcription skipped: model not loaded.")
                return {"raw": "", "cleaned": ""}

            try:
                raw_text = adapter.transcribe_file(tmp_path).strip()
            except Exception as exc:
                # Never let a single bad clip break dictation — fail soft to empty.
                print(f"Transcription failed, returning empty: {exc}")
                return {"raw": "", "cleaned": ""}
        finally:
            os.unlink(tmp_path)

        if cleanup:
            cleaned_text = await run_in_threadpool(
                clean_with_gateway, raw_text, context, list(recent_transcripts), screen
            )
        else:
            cleaned_text = raw_text

        # Learning system: apply the user's learned corrections as the final step
        # so they always win over whatever the models produced.
        cleaned_text = corrections.apply(cleaned_text)

        # Remember what we produced so the next dictation has continuity.
        if raw_text.strip():
            recent_transcripts.append(cleaned_text)

        return {"raw": raw_text, "cleaned": cleaned_text}

    @app.post("/learn")
    async def learn(original: str = Form(...), edited: str = Form(...)):
        learned = await run_in_threadpool(corrections.learn_from_edit, original, edited)
        return {"learned": learned, "total": len(corrections.data)}

    @app.get("/corrections")
    def get_corrections():
        return {"corrections": corrections.list()}

    @app.post("/corrections/add")
    def add_correction(frm: str = Form(...), to: str = Form(...)):
        """Manually add a correction (e.g. from the Settings UI)."""
        added = corrections.add(frm, to)
        return {"added": added, "corrections": corrections.list()}

    @app.post("/corrections/update")
    def update_correction(key: str = Form(...), frm: str = Form(...), to: str = Form(...)):
        """Edit an existing correction's from/to text."""
        updated = corrections.update(key, frm, to)
        return {"updated": updated, "corrections": corrections.list()}

    @app.post("/corrections/delete")
    def delete_correction(key: str = Form(...)):
        existed = corrections.delete(key)
        return {"deleted": existed}

    @app.post("/corrections/clear")
    def clear_corrections():
        corrections.clear()
        return {"cleared": True}

    # --- Model download management (delegated to the platform adapter) -----------

    @app.get("/model/status")
    def model_status():
        """Report whether the STT model is present/loaded and any download
        progress. Response shape is fixed by docs/CONTRACT.md; the adapter fills
        the platform-specific file/progress fields.
        """
        snap = adapter.status_snapshot()
        return {
            "model_present": adapter.is_present(),
            "model_loaded": adapter.is_loaded(),
            "active": snap.get("active", False),
            "phase": snap.get("phase", "idle"),
            "current_file": snap.get("current_file", ""),
            "downloaded": snap.get("downloaded", 0),
            "file_total": snap.get("file_total", 0),
            "overall_done": snap.get("overall_done", 0),
            "overall_total": snap.get("overall_total", 0),
            "error": snap.get("error", ""),
            "model_dir": snap.get("model_dir", ""),
            "model_id": snap.get("model_id", ""),
        }

    @app.post("/model/download")
    def model_download():
        """Start a background download of the STT model. Returns immediately;
        poll /model/status for progress. Idempotent. When the files are all
        present the model is loaded in-process so dictation works without a
        sidecar restart.
        """
        return adapter.start_download()

    return app