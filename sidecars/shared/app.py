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

from fastapi import FastAPI, File, Form, Header, Query, UploadFile
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from sidecars.shared.audio import MIN_AUDIO_SECONDS, wav_duration_seconds
from sidecars.shared.cleanup import NotEntitled, check_entitlement, clean_with_gateway
from sidecars.shared.corrections import Corrections

# Option A: keep the last few cleaned dictations so the model has continuity.
RECENT_HISTORY_N = 3


class SttAdapter:
    """Interface every platform's STT engine implements.

    The shared app calls only these methods; it never imports a model library
    or touches the on-disk model directory directly.
    """

    #: Why the last :meth:`load` failed; empty when it succeeded or was never
    #: attempted. Without this a model that is on disk but cannot start looks
    #: to the client exactly like one that was never downloaded, and the only
    #: trace of the real cause is a log nobody opens. Adapters set it in
    #: :meth:`load`; the app factory backstops it if they don't.
    load_error: str = ""

    def runtime_label(self) -> str:
        """Human name for the compute path inference actually runs on, once
        loaded — e.g. ``"GPU (DirectML)"`` or ``"CPU"``. Empty when unknown.

        The client states where transcription happens; a silent fall back to a
        far slower path should change what it says.
        """
        return ""

    def is_loaded(self) -> bool:
        """True iff the STT model is resident in memory and ready to transcribe."""
        raise NotImplementedError

    def is_present(self) -> bool:
        """True iff all model files exist on disk (may be present but unloaded)."""
        raise NotImplementedError

    def load(self) -> None:
        """Load the model into memory. Called at startup and after a download.

        Must be idempotent and must set whatever state ``is_loaded`` reads.
        Must leave the model unloaded on failure, set :attr:`load_error` to the
        reason, and re-raise — callers decide whether that is fatal (the app
        still serves /health and /model/status; /transcribe returns empty).

        ``is_loaded`` must mean *usable*, not merely *constructed*: where an
        engine can build a session that then fails on its first inference,
        verify with a real forward pass before publishing the model.
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
        May also return ``variant, variant_label, variant_reason,
        download_bytes`` where the platform ships more than one build of the
        model; omitting them reports "no choice to make".
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
            #
            # Recorded, not merely printed. A startup load failure with the
            # files already on disk is the one case the dashboard used to have
            # no words for: it saw "present, not loaded" and offered to restart
            # an engine that was already running.
            if not adapter.load_error:
                adapter.load_error = str(exc)
            print(f"Could not load model at startup: {exc}")
        yield

    app = FastAPI(lifespan=lifespan)

    @app.get("/health")
    def health():
        return {
            "status": "ok",
            "model_loaded": adapter.is_loaded(),
            "model_present": adapter.is_present(),
            # Carried on the liveness probe as well as /model/status so the
            # client's always-on health poll can tell "not downloaded yet" from
            # "downloaded, but it will not start" without a second request.
            "load_error": adapter.load_error,
        }

    class NotEntitledResponse(JSONResponse):
        """402 with the gateway's own wording, so the app shows it verbatim."""

        def __init__(self, message: str, code: str = "not_entitled"):
            super().__init__(
                status_code=402,
                content={"error": code, "message": message},
            )

    @app.post("/transcribe")
    async def transcribe(
        file: UploadFile = File(...),
        cleanup: bool = Query(True),
        context: str = Form(""),
        screen: str = Form(""),
        tone: str = Form(""),
        app_id: str = Form("", alias="app"),
        app_site: str = Form(""),
        app_detail: str = Form(""),
        device_key: str = Header("", alias="X-SunoFlow-Device-Key"),
    ):
        """Transcribe a clip, and refuse if this device may not dictate.

        The device key travels per request from the app's credential store
        rather than living in the sidecar's environment: re-pairing then takes
        effect immediately with no restart, and the key is never written to disk
        outside that store.
        """
        key = device_key.removeprefix("Bearer ").strip()
        try:
            return await _transcribe_inner(
                file, cleanup, context, screen, tone, key,
                app_id, app_site, app_detail,
            )
        except NotEntitled as exc:
            # Deliberately NOT a soft failure: an expired or unconnected account
            # stops working rather than quietly dropping to a free tier.
            print(f"Refusing dictation — {exc}")
            return NotEntitledResponse(str(exc), getattr(exc, "code", "not_entitled"))

    async def _transcribe_inner(
        file, cleanup, context, screen, tone, key,
        app_id="", app_site="", app_detail="",
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
            # Only the entries this transcript could plausibly need — the rest of
            # the dictionary stays on the machine.
            relevant = corrections.relevant_for(raw_text)
            cleaned_text = await run_in_threadpool(
                clean_with_gateway, raw_text, context, list(recent_transcripts), screen,
                key, relevant, tone, app_id, app_site, app_detail,
            )
        else:
            # Cleanup off still has to prove entitlement, or switching it off
            # would be a free-dictation switch: it skips the only server call.
            # A tone chosen while cleanup is off does nothing, and cannot: the
            # voice is applied by the model, and this path makes no model call.
            # The apps are expected to gate the tone picker on cleanup being on
            # rather than leaving the key looking broken.
            await run_in_threadpool(check_entitlement, key)
            cleaned_text = raw_text

        # Apply the learned corrections as the final step so they always win over
        # whatever the models produced. Expansions are not applied here — they
        # need the model's judgement about whether the speaker was giving the
        # value or just mentioning the thing, so with cleanup off they simply do
        # not fire. See Corrections.apply.
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
    def add_correction(frm: str = Form(...), to: str = Form(...), kind: str = Form("")):
        """Manually add an entry (e.g. from the Settings UI).

        ``kind`` is optional — the UI does not ask, and an unset kind is
        inferred from the shape of the pair.
        """
        added = corrections.add(frm, to, kind)
        return {"added": added, "corrections": corrections.list()}

    @app.post("/corrections/update")
    def update_correction(
        key: str = Form(...), frm: str = Form(...), to: str = Form(...), kind: str = Form("")
    ):
        """Edit an existing entry's from/to text."""
        updated = corrections.update(key, frm, to, kind)
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
            # Distinct from ``error``: that one is about fetching the files,
            # this one about starting them. By the time a load fails the
            # download has already succeeded, and telling the user to download
            # 2.5 GB again would not fix it.
            "load_error": adapter.load_error,
            "runtime": adapter.runtime_label(),
            # Which build of the model this machine runs, and why. Windows picks
            # between a full-precision and an int8 export from the hardware it
            # finds; macOS has one build and leaves these empty. Empty means
            # "no choice to report", not "unknown" — clients hide the row.
            "variant": snap.get("variant", ""),
            "variant_label": snap.get("variant_label", ""),
            "variant_reason": snap.get("variant_reason", ""),
            "download_bytes": snap.get("download_bytes", 0),
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