"""FastAPI app factory + all HTTP routes — the shared sidecar skeleton.

Every sidecar (macOS parakeet-mlx, Windows onnxruntime-directml) implements the
``SttAdapter`` interface and calls ``create_app(adapter, corrections_path)``.
The HTTP contract is documented in ``docs/CONTRACT.md`` and MUST be identical
across platforms.

What stays platform-specific (lives in the adapter, NOT here):
  - model loading, inference, and the model's on-disk location
  - the model download manager (file manifest + source URLs differ per platform)
"""
import json
import os
import tempfile
import threading
import time
from collections import deque
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, Header, Query, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.concurrency import run_in_threadpool

from sidecars.shared.answer import MAX_QUERY_LEN, _sse_bytes, stream_answer
from sidecars.shared.audio import MIN_AUDIO_SECONDS, encode_opus, wav_duration_seconds
from sidecars.shared.cleanup import (
    NotEntitled,
    check_entitlement,
    clean_with_gateway,
    keepalive_gateway,
    transcribe_with_gateway,
)
from sidecars.shared.corrections import Corrections
from sidecars.shared.warmstart import (
    ROUTE_CLOUD,
    ROUTE_LOCAL,
    ROUTE_SHADOW,
    ROUTE_WAIT,
    WarmStartController,
    real_time_factor,
    word_agreement,
)

# Option A: keep the last few cleaned dictations so the model has continuity.
RECENT_HISTORY_N = 3


def _cloud_stt_enabled() -> bool:
    """Master switch for the cloud warm-start path (SUNOFLOW_CLOUD_STT).

    On by default; a dev run or a deployment that never wants cloud STT sets it
    to 0/false to keep every dictation on-device (or waiting for the model). The
    per-request consent flag still gates it on top of this.
    """
    return os.environ.get("SUNOFLOW_CLOUD_STT", "1").strip().lower() not in ("0", "false", "no", "")


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

    # Warm-start controller: routes dictation cloud→local while the model
    # downloads, validates local against the cloud, and cuts over. Its cutover
    # verdict persists next to the corrections file so a machine that already
    # migrated does not reopen the cloud path on the next launch.
    warmstart = WarmStartController.from_env(
        enabled=_cloud_stt_enabled(),
        state_path=os.path.join(os.path.dirname(corrections_path), "warmstart.json"),
    )
    # An install that already has the model on disk never needed warm-start:
    # treat it as already migrated so an upgrade does not start sending audio to
    # the cloud to "validate" a model it has been transcribing with locally all
    # along. New installs launch with nothing on disk, so this does not fire for
    # them; and once a device has cut over the persisted verdict already covers it.
    if not warmstart.cut_over and adapter.is_present():
        warmstart.force_local()

    def _local_transcribe(path: str) -> str:
        """Run local inference, soft-failing to "" — never breaks a dictation.

        Runs on the caller's thread (the event loop), which is required: MLX's
        default stream is thread-local, so inference must happen on the thread the
        model was loaded on, not a threadpool worker.
        """
        try:
            return adapter.transcribe_file(path).strip()
        except Exception as exc:
            print(f"Transcription failed, returning empty: {exc}")
            return ""

    def _local_transcribe_timed(path: str, audio_seconds) -> tuple:
        """Local inference plus its real-time factor, for the shadow comparison.

        A failure returns ("", inf): agreement then scores 0 and the speed gate
        never passes, so a broken local model can never trigger a cutover.
        """
        t0 = time.perf_counter()
        try:
            text = adapter.transcribe_file(path).strip()
        except Exception as exc:
            print(f"Shadow local transcription failed: {exc}")
            return "", float("inf")
        return text, real_time_factor(time.perf_counter() - t0, audio_seconds)

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
        # Keep the gateway TLS connection warm so dictations after an idle gap
        # don't pay a fresh handshake on the critical path. Daemon; dies with us.
        threading.Thread(
            target=keepalive_gateway, name="sf-gateway-keepalive", daemon=True
        ).start()
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
        # The user's per-install consent to cloud STT while the local model
        # downloads. Defaults False so a client that never sends it (or a user
        # who declined) never leaves the device — the warm-start path is opt-in.
        allow_cloud: bool = Form(False),
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
                app_id, app_site, app_detail, allow_cloud,
            )
        except NotEntitled as exc:
            # Deliberately NOT a soft failure: an expired or unconnected account
            # stops working rather than quietly dropping to a free tier.
            print(f"Refusing dictation — {exc}")
            return NotEntitledResponse(str(exc), getattr(exc, "code", "not_entitled"))

    async def _transcribe_inner(
        file, cleanup, context, screen, tone, key,
        app_id="", app_site="", app_detail="", allow_cloud=False,
    ):
        audio_bytes = await file.read()
        fd, tmp_path = tempfile.mkstemp(suffix=".wav")
        try:
            with os.fdopen(fd, "wb") as tmp:
                tmp.write(audio_bytes)

            # STT engines underflow on empty/too-short audio: the mel length goes
            # negative and wraps to a huge unsigned value, so inference tries to
            # allocate ~2**64 bytes and the whole request 500s. Skip clips that
            # are too short to contain speech (accidental taps, a glitchy first
            # record right after boot) and return an empty transcript instead.
            duration = wav_duration_seconds(tmp_path)
            if duration is None or duration < MIN_AUDIO_SECONDS:
                print(f"Skipping transcription: audio too short ({duration} s)")
                return {"raw": "", "cleaned": ""}

            # Warm-start routing. The controller decides where this dictation is
            # transcribed given the user's cloud consent and whether the local
            # model is loaded yet; see warmstart.py for the state machine.
            route = warmstart.route(consent=allow_cloud, model_loaded=adapter.is_loaded())

            # Whether the cloud STT call ran. It enforces entitlement on its own,
            # so a cloud/shadow route needs no separate check below.
            used_gateway_stt = False
            # Which engine produced raw_text, sent to the gateway for its
            # local-vs-cloud analytics. Default local; cloud/shadow override.
            stt_source = "local"

            if route == ROUTE_WAIT:
                # No cloud allowed and the model isn't loaded yet — the pre-feature
                # behaviour: a soft empty result rather than crashing on inference.
                print("Transcription skipped: model not loaded (cloud STT off).")
                return {"raw": "", "cleaned": ""}

            # For a cloud call, compress the WAV to Ogg/Opus (~10x smaller) to
            # shrink the upload; falls back to raw WAV if compression is
            # off/unavailable (e.g. no ffmpeg on Windows).
            upload_bytes, upload_fmt = audio_bytes, "wav"
            if route in (ROUTE_CLOUD, ROUTE_SHADOW):
                opus = await run_in_threadpool(encode_opus, tmp_path)
                if opus:
                    upload_bytes, upload_fmt = opus, "ogg"
                    print(f"[stt] opus upload {len(opus)}B (from {len(audio_bytes)}B wav)")

            if route == ROUTE_CLOUD:
                # Serve the cloud now, and make sure the local model is downloading
                # in the background so the device can cut over to on-device later.
                try:
                    adapter.start_download()
                except Exception as exc:
                    print(f"Could not start background model download: {exc}")
                raw_text = await run_in_threadpool(
                    transcribe_with_gateway, upload_bytes, key, upload_fmt, ""
                )
                used_gateway_stt = True
                stt_source = "cloud"

            elif route == ROUTE_LOCAL:
                raw_text = _local_transcribe(tmp_path)

            else:  # ROUTE_SHADOW
                # Cloud stays authoritative during validation; local runs silently
                # on the same audio so we can compare speed and accuracy before
                # trusting it. The user never sees the unvalidated local result.
                local_text, rtf = _local_transcribe_timed(tmp_path, duration)
                cloud_text = await run_in_threadpool(
                    transcribe_with_gateway, upload_bytes, key, upload_fmt, ""
                )
                used_gateway_stt = True
                if cloud_text:
                    warmstart.record_shadow(
                        rtf=rtf, agreement=word_agreement(local_text, cloud_text)
                    )
                    raw_text = cloud_text
                    stt_source = "cloud"
                else:
                    # Cloud missed this one (a lease-covered outage): fall back to
                    # the local result we already produced rather than dropping the
                    # dictation. No sample is recorded — there was nothing to
                    # compare local against.
                    raw_text = local_text
                    stt_source = "local"
        finally:
            os.unlink(tmp_path)

        if cleanup:
            # Only the entries this transcript could plausibly need — the rest of
            # the dictionary stays on the machine.
            relevant = corrections.relevant_for(raw_text)
            cleaned_text = await run_in_threadpool(
                clean_with_gateway, raw_text, context, list(recent_transcripts), screen,
                key, relevant, tone, app_id, app_site, app_detail, stt_source,
            )
        else:
            # Cleanup off still has to prove entitlement, or switching it off
            # would be a free-dictation switch: it skips the only server call.
            # A tone chosen while cleanup is off does nothing, and cannot: the
            # voice is applied by the model, and this path makes no model call.
            # The apps are expected to gate the tone picker on cleanup being on
            # rather than leaving the key looking broken.
            #
            # Skip it when the cloud STT call already ran this dictation — that
            # call enforced entitlement itself, so a second round trip would be
            # redundant.
            if not used_gateway_stt:
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

    @app.post("/answer")
    async def answer(
        query: str = Form(...),
        history: str = Form("[]"),
        image: UploadFile = File(None),
        device_key: str = Header("", alias="X-SunoFlow-Device-Key"),
    ):
        """Proxy one Suno Answer turn to the hosted gateway as SSE.

        ``query`` is this turn's dictated question; ``history`` is a JSON array
        of prior ``{q, a}`` pairs, oldest first, carried from the app's in-memory
        popup session (A2: nothing persists server-side). ``image`` rides the
        FIRST turn of a session only (F3/A9 — the screen is frozen once the
        popup appears; the model cannot re-look, and follow-ups carry text
        history only).

        The dictionary slice is selected from the corrections file here (D8),
        keyed on the query — same ``relevant_for`` machinery as /transcribe,
        different key. The response is always ``text/event-stream``: the
        gateway's SSE bytes pass through, and pre-stream failures (refusal,
        limit, outage) are translated into that stream as a single ``error``
        event so the app parses one shape.
        """
        key = device_key.removeprefix("Bearer ").strip()
        try:
            turns = json.loads(history) if history else []
            if not isinstance(turns, list):
                turns = []
        except Exception:
            turns = []

        image_bytes = b""
        if image is not None:
            image_bytes = await image.read()

        # Correct the dictated query against the user's dictionary BEFORE the
        # gateway sees it: a question built from mis-heard words searches for
        # mis-heard words. In-process regex pass — microseconds, no extra
        # round trip (latency was the constraint). Corrections only, exactly
        # like /transcribe: expansions need the model's judgement about
        # whether the speaker was giving the value or just mentioning the
        # thing, so they are never substituted blind.
        corrected = query.strip()[:MAX_QUERY_LEN]
        if corrected:
            corrected = corrections.apply(corrected).strip()[:MAX_QUERY_LEN] or corrected

        # The gateway refuses a disconnected device (401/402/403 with our JSON
        # body) exactly as it does for dictation — same NotEntitled path.
        try:
            relevant = corrections.relevant_for(query, limit=40)
            gen = await run_in_threadpool(
                stream_answer, corrected or query, turns, image_bytes, key, relevant
            )
        except NotEntitled as exc:
            print(f"Refusing Suno Answer — {exc}")
            return NotEntitledResponse(str(exc), getattr(exc, "code", "not_entitled"))
        except ValueError as exc:
            # Bad query/image from the app itself: the app's own SSE parser
            # still needs the event shape, so even this comes back in-stream.
            return StreamingResponse(
                _error_stream(str(exc), "unavailable"),
                media_type="text/event-stream",
            )

        # Tell the app when the dictionary fixed the query: one ``query`` event
        # ahead of the gateway's stream. The app swaps its user bubble to the
        # corrected wording — that visible fix is the "we heard you right"
        # feedback. Nothing is prepended when nothing changed (the common
        # case), so the stream stays byte-for-byte gateway output.
        if corrected and corrected != query.strip()[:MAX_QUERY_LEN]:
            prefix = _sse_bytes("query", {"query": corrected})

            def _prefixed(inner=gen):
                yield prefix
                for chunk in inner:
                    yield chunk

            gen = _prefixed()

        return StreamingResponse(
            gen,
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    def _error_stream(message: str, code: str):
        yield (
            f"event: error\ndata: {json.dumps({'error': code, 'message': message})}\n\n"
        ).encode("utf-8")

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
            # Warm-start state so the app can show a "Cloud → On-device" banner.
            # Consent-independent fields only (cut_over, progress, gates); the app
            # combines them with its own cloud-consent pref and model_loaded to
            # decide what to display. Additive — older clients ignore it.
            "warm_start": _warm_start_status(),
        }

    def _warm_start_status() -> dict:
        snap = warmstart.snapshot(model_loaded=adapter.is_loaded())
        return {
            "cut_over": snap["cut_over"],
            "enabled": snap["enabled"],
            "samples": snap["samples"],
            "median_rtf": snap["median_rtf"],
            "median_agreement": snap["median_agreement"],
            "rtf_target": snap["rtf_target"],
            "min_agreement": snap["min_agreement"],
            "min_samples": snap["min_samples"],
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