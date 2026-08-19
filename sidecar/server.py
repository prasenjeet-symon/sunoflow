import json
import os
import re
import tempfile
import threading
import wave
from collections import deque
from contextlib import asynccontextmanager
from difflib import SequenceMatcher

import requests
from fastapi import FastAPI, File, Form, Query, UploadFile
from starlette.concurrency import run_in_threadpool

import parakeet_mlx

MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"

# --- Cleanup gateway (hosted) -------------------------------------------------
# Cleanup/LLM no longer runs locally. The sidecar POSTs the transcript to a
# remote cleanup gateway (Go service, see cleanup-gateway/) which owns the
# cleanup instruction, the LLM backend (Ollama/OpenAI/Claude), and the
# echo-retry guard — so the live path is a single POST that soft-fails to raw
# text on any error. The Swift app probes the gateway's /ready directly for
# its connectivity status; the sidecar no longer surfaces /config or /models.
# Override with SUNOFLOW_CLEANUP_URL / SUNOFLOW_CLEANUP_KEY for dev (e.g.
# point at a local docker-compose stack).
CLEANUP_URL = os.environ.get("SUNOFLOW_CLEANUP_URL", "https://cleanup.mirrorli.art/cleanup")
CLEANUP_KEY = os.environ.get("SUNOFLOW_CLEANUP_KEY", "FQ2xxpibf5RBIeEzouwSXxU0Nn2sz-nI2H1STykqr1A")

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

# Option A: keep the last few cleaned dictations so the model has continuity.
RECENT_HISTORY_N = 3
recent_transcripts: "deque[str]" = deque(maxlen=RECENT_HISTORY_N)

# Clips shorter than this can't hold real speech and make parakeet-mlx underflow
# (empirically it crashes below ~0.01s; 0.1s is a safe "too short to be speech"
# cutoff with margin). Below it we skip the model and return an empty transcript.
MIN_AUDIO_SECONDS = 0.1


def _wav_duration_seconds(path: str):
    """Duration of a PCM WAV in seconds, or None if it can't be read."""
    try:
        with wave.open(path, "rb") as w:
            rate = w.getframerate()
            if not rate:
                return None
            return w.getnframes() / float(rate)
    except Exception:
        return None

# --- Learning system: a personal correction dictionary -----------------------
# We watch what the user edits after each paste and learn recurring word/short-
# phrase substitutions (e.g. "cavach" -> "Kavach"), then apply them to future
# transcripts. Stored locally; nothing leaves the machine.
CORRECTIONS_PATH = os.path.join(os.path.dirname(__file__), "corrections.json")

# Common words we won't auto-learn as global replacements: swapping these is
# context-dependent (there/their) and a blanket replace would do harm.
_COMMON_WORDS = {
    "a", "an", "the", "and", "or", "but", "if", "then", "so", "to", "of", "in",
    "on", "at", "for", "with", "by", "as", "is", "are", "was", "were", "be",
    "it", "its", "this", "that", "these", "those", "there", "their", "theyre",
    "they", "your", "youre", "you", "our", "we", "he", "she", "him", "her",
    "his", "hers", "them", "i", "me", "my", "no", "not", "yes", "do", "does",
    "did", "has", "have", "had", "will", "would", "can", "could", "should",
    "than", "then", "too", "two", "to", "here", "hear", "where", "were",
}


def _load_corrections() -> dict:
    try:
        with open(CORRECTIONS_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_corrections(data: dict) -> None:
    tmp = CORRECTIONS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, CORRECTIONS_PATH)


# key (normalized "from") -> {"from": str, "to": str, "count": int}
corrections = _load_corrections()


def _norm_key(s: str) -> str:
    return s.strip().strip(".,!?;:\"'`()[]").lower()


def _worth_learning(old: str, new: str) -> bool:
    """Bias toward distinctive names / technical terms, which are safe to replace
    globally, and away from context-dependent common-word swaps."""
    if not re.search(r"\w", old) or not re.search(r"\w", new):
        return False
    # Proper nouns, acronyms, and terms with digits are safe global replacements.
    if any(c.isupper() for c in new) or any(c.isdigit() for c in new):
        return True
    # Otherwise, don't learn if either side is a common word (e.g. there/their).
    if _norm_key(new) in _COMMON_WORDS or _norm_key(old) in _COMMON_WORDS:
        return False
    return True


def extract_correction_pairs(original: str, edited: str):
    """Word-level diff -> short, mishearing-like substitutions only."""
    o = original.split()
    e = edited.split()
    matcher = SequenceMatcher(a=o, b=e, autojunk=False)
    pairs = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace":
            continue
        if not (0 < (i2 - i1) <= 3) or not (0 < (j2 - j1) <= 3):
            continue  # too big -> a rewrite, not a term fix
        old = " ".join(o[i1:i2]).strip(".,!?;:\"'`()[]").strip()
        new = " ".join(e[j1:j2]).strip(".,!?;:\"'`()[]").strip()
        if not old or not new or _norm_key(old) == _norm_key(new):
            continue
        # Mishearings are character-similar; rewrites are not.
        if SequenceMatcher(None, _norm_key(old), _norm_key(new)).ratio() < 0.5:
            continue
        if not _worth_learning(old, new):
            continue
        pairs.append((old, new))
    return pairs


def learn_from_edit(original: str, edited: str):
    learned = []
    for old, new in extract_correction_pairs(original, edited):
        key = _norm_key(old)
        entry = corrections.get(key, {"from": old, "to": new, "count": 0})
        entry["from"] = old
        entry["to"] = new
        entry["count"] = entry.get("count", 0) + 1
        corrections[key] = entry
        learned.append({"from": old, "to": new, "count": entry["count"]})
    if learned:
        _save_corrections(corrections)
    return learned


def apply_corrections(text: str) -> str:
    if not corrections or not text:
        return text
    result = text
    # Longer phrases first so multi-word fixes win over single-word ones.
    for key in sorted(corrections, key=len, reverse=True):
        frm = corrections[key]["from"]
        to = corrections[key]["to"]
        result = re.sub(r"\b" + re.escape(frm) + r"\b", to, result, flags=re.IGNORECASE)
    return result

model = None
# Lazily import mlx only when we actually load weights — importing mlx spins up
# the Metal device, which we don't want to pay for if the model isn't present.


def _local_model_complete() -> bool:
    """True if the managed model directory has every file we need."""
    return all(
        os.path.exists(os.path.join(MODEL_DIR, f)) for f in MODEL_FILES
    )


def _load_model_now() -> None:
    """Load the Parakeet model into the global `model`, from disk when available."""
    global model
    if _local_model_complete():
        print(f"Loading model from {MODEL_DIR} ...")
        model = parakeet_mlx.from_pretrained(MODEL_DIR)
        print("Model loaded from managed directory.")
    else:
        # Fall back to the HuggingFace cache for existing installs that haven't
        # migrated to the managed directory yet. This keeps dev setups working.
        print(f"Managed model not found; loading {MODEL_ID} from HF cache ...")
        model = parakeet_mlx.from_pretrained(MODEL_ID)
        print("Model loaded from HF cache.")


# --- Background model download -------------------------------------------------
# Tracks an in-progress download so the UI can poll /model/download and so a
# second click doesn't start two competing downloads. All fields are guarded by
# _dl_lock.
_dl_lock = threading.Lock()
_dl_state = {
    "active": False,
    "phase": "idle",        # idle | downloading | loading | done | error
    "current_file": "",
    "downloaded": 0,        # bytes downloaded so far for the current file
    "file_total": 0,        # total bytes for the current file
    "overall_done": 0,      # number of files finished
    "overall_total": len(MODEL_FILES),
    "error": "",
}


def _dl_snapshot() -> dict:
    with _dl_lock:
        snap = dict(_dl_state)
    snap["model_present"] = _local_model_complete()
    return snap


def _download_file(url: str, dest: str) -> None:
    """Stream a single file to disk, updating _dl_state progress as bytes arrive."""
    import requests as _requests

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    with _requests.get(url, stream=True, timeout=60) as r:
        r.raise_for_status()
        total = int(r.headers.get("Content-Length", 0))
        with _dl_lock:
            _dl_state["file_total"] = total
            _dl_state["downloaded"] = 0
            _dl_state["current_file"] = os.path.basename(dest)
        written = 0
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):  # 1 MiB
                if not chunk:
                    continue
                f.write(chunk)
                written += len(chunk)
                with _dl_lock:
                    _dl_state["downloaded"] = written
    os.replace(tmp, dest)


def _run_download() -> None:
    """Worker thread: fetch every model file, then load the model in-process."""
    global model
    try:
        os.makedirs(MODEL_DIR, exist_ok=True)
        with _dl_lock:
            _dl_state.update(
                active=True, phase="downloading", overall_done=0,
                error="", current_file="",
            )
        for i, fname in enumerate(MODEL_FILES):
            dest = os.path.join(MODEL_DIR, fname)
            if os.path.exists(dest):
                # Already have this file (e.g. a resume). Skip but count it.
                with _dl_lock:
                    _dl_state["overall_done"] = i + 1
                continue
            _download_file(f"{HF_BASE}/{fname}", dest)
            with _dl_lock:
                _dl_state["overall_done"] = i + 1

        with _dl_lock:
            _dl_state.update(phase="loading", current_file="")
        _load_model_now()
        with _dl_lock:
            _dl_state.update(phase="done", active=False)
    except Exception as exc:
        print(f"Model download failed: {exc}")
        with _dl_lock:
            _dl_state.update(phase="error", active=False, error=str(exc))


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    try:
        _load_model_now()
    except Exception as exc:
        # If the model can't be loaded (e.g. nothing in the managed dir AND the
        # HF cache is empty / offline), don't crash the whole sidecar — the user
        # can trigger a download from the dashboard and we'll load on demand.
        print(f"Could not load model at startup: {exc}")
        model = None
    yield


app = FastAPI(lifespan=lifespan)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model_loaded": model is not None,
        "model_present": _local_model_complete(),
    }


def clean_with_ollama(text: str, context: str = "", recent: list = None, screen: str = "") -> str:
    """Clean a transcript via the hosted cleanup gateway.

    The gateway (cleanup-gateway/) owns the cleanup instruction, the LLM
    backend (Ollama/OpenAI/Claude), and the echo-retry guard — so this is a
    single POST. On ANY error (network, auth, timeout, non-200) we fall back to
    the raw text so dictation never fails because cleanup is down. This matches
    the old local-Ollama soft-fail behaviour byte for byte.
    """
    if not text.strip():
        return text
    recent = recent or []
    context = (context or "").strip()
    screen = (screen or "").strip()

    try:
        resp = requests.post(
            CLEANUP_URL,
            headers={"Authorization": f"Bearer {CLEANUP_KEY}"},
            json={"text": text, "context": context, "recent": recent, "screen": screen},
            timeout=60,
        )
        resp.raise_for_status()
        cleaned = (resp.json().get("cleaned") or "").strip()
        # Gateway already applies echo-retry, but guard against an empty payload
        # falling through — return raw rather than an empty string.
        return cleaned or text
    except Exception as exc:
        print(f"Cleanup gateway failed, falling back to raw text: {exc}")
        return text


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

        # parakeet-mlx underflows on empty/too-short audio: the mel length goes
        # negative and wraps to a huge unsigned value, so mx.eval tries to
        # allocate ~2**64 bytes and the whole request 500s. Skip clips that are
        # too short to contain speech (accidental taps, a glitchy first record
        # right after boot) and return an empty transcript instead.
        duration = _wav_duration_seconds(tmp_path)
        if duration is None or duration < MIN_AUDIO_SECONDS:
            print(f"Skipping transcription: audio too short ({duration} s)")
            return {"raw": "", "cleaned": ""}

        if model is None:
            # The sidecar is up but the STT model isn't loaded yet (user hasn't
            # downloaded it, or the download is still running). Surface this as
            # a soft empty result rather than crashing on None.transcribe.
            print("Transcription skipped: model not loaded.")
            return {"raw": "", "cleaned": ""}

        # MLX's default stream is thread-local, so transcribe must run on the
        # same thread the model was loaded on (the event loop thread), not a
        # threadpool worker.
        try:
            result = model.transcribe(tmp_path)
            raw_text = result.text.strip()
        except Exception as exc:
            # Never let a single bad clip break dictation — fail soft to empty.
            print(f"Transcription failed, returning empty: {exc}")
            return {"raw": "", "cleaned": ""}
    finally:
        os.unlink(tmp_path)

    if cleanup:
        cleaned_text = await run_in_threadpool(
            clean_with_ollama, raw_text, context, list(recent_transcripts), screen
        )
    else:
        cleaned_text = raw_text

    # Learning system: apply the user's learned corrections as the final step so
    # they always win over whatever the models produced.
    cleaned_text = apply_corrections(cleaned_text)

    # Option A: remember what we produced so the next dictation has continuity.
    if raw_text.strip():
        recent_transcripts.append(cleaned_text)

    return {"raw": raw_text, "cleaned": cleaned_text}


@app.post("/learn")
async def learn(original: str = Form(...), edited: str = Form(...)):
    learned = await run_in_threadpool(learn_from_edit, original, edited)
    return {"learned": learned, "total": len(corrections)}


def _corrections_list():
    return [
        {"key": k, "from": v["from"], "to": v["to"], "count": v.get("count", 1)}
        for k, v in sorted(corrections.items())
    ]


@app.get("/corrections")
def get_corrections():
    return {"corrections": _corrections_list()}


@app.post("/corrections/add")
def add_correction(frm: str = Form(...), to: str = Form(...)):
    """Manually add a correction (e.g. from the Settings UI)."""
    key = _norm_key(frm)
    if not key:
        return {"added": False, "corrections": _corrections_list()}
    # Preserve the count if the same key already existed.
    count = corrections.get(key, {}).get("count", 0)
    corrections[key] = {"from": frm.strip(), "to": to.strip(), "count": count}
    _save_corrections(corrections)
    return {"added": True, "corrections": _corrections_list()}


@app.post("/corrections/update")
def update_correction(key: str = Form(...), frm: str = Form(...), to: str = Form(...)):
    """Edit an existing correction's from/to text."""
    old = corrections.pop(key, None)
    new_key = _norm_key(frm)
    if not new_key:
        # Restore the old entry if the new "from" is blank.
        if old is not None:
            corrections[key] = old
        return {"updated": False, "corrections": _corrections_list()}
    count = (old or {}).get("count", corrections.get(new_key, {}).get("count", 0))
    corrections[new_key] = {"from": frm.strip(), "to": to.strip(), "count": count}
    _save_corrections(corrections)
    return {"updated": True, "corrections": _corrections_list()}


@app.post("/corrections/delete")
def delete_correction(key: str = Form(...)):
    existed = corrections.pop(key, None) is not None
    if existed:
        _save_corrections(corrections)
    return {"deleted": existed}


@app.post("/corrections/clear")
def clear_corrections():
    corrections.clear()
    _save_corrections(corrections)
    return {"cleared": True}


# --- Model download management -------------------------------------------------

@app.get("/model/status")
def model_status():
    """Report whether the STT model is present/loaded and any download progress."""
    snap = _dl_snapshot()
    return {
        "model_present": snap["model_present"],
        "model_loaded": model is not None,
        "active": snap["active"],
        "phase": snap["phase"],
        "current_file": snap["current_file"],
        "downloaded": snap["downloaded"],
        "file_total": snap["file_total"],
        "overall_done": snap["overall_done"],
        "overall_total": snap["overall_total"],
        "error": snap["error"],
        "model_dir": MODEL_DIR,
        "model_id": MODEL_ID,
    }


@app.post("/model/download")
def model_download():
    """Start a background download of the Parakeet model into MODEL_DIR.

    Returns immediately; poll /model/status for progress. If a download is
    already running this is a no-op. When the files are all present the model
    is loaded in-process so dictation works without a sidecar restart.
    """
    with _dl_lock:
        if _dl_state["active"]:
            return {"started": False, "reason": "already_running"}
    if _local_model_complete() and model is not None:
        return {"started": False, "reason": "already_present"}
    threading.Thread(target=_run_download, daemon=True).start()
    return {"started": True}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8765)
