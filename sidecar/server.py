import json
import os
import platform
import re
import tempfile
import threading
import time
import wave
from collections import deque
from contextlib import asynccontextmanager
from difflib import SequenceMatcher

import requests
from requests.adapters import HTTPAdapter, Retry
from fastapi.responses import JSONResponse
from fastapi import FastAPI, File, Form, Query, UploadFile, Header
from starlette.concurrency import run_in_threadpool

import parakeet_mlx

import lease

MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"

# --- Cleanup gateway (hosted) -------------------------------------------------
# Cleanup/LLM no longer runs locally. The sidecar POSTs the transcript to a
# remote cleanup gateway (Go service, see cleanup-gateway/) which owns the
# cleanup instruction, the LLM backend (Gemini), and the
# echo-retry guard — so the live path is a single POST that soft-fails to raw
# text on any error. The Swift app probes the gateway's /ready directly for
# its connectivity status; the sidecar no longer surfaces /config or /models.
# Override with SUNOFLOW_CLEANUP_URL / SUNOFLOW_CLEANUP_KEY for dev (e.g.
# point at a local docker-compose stack).
CLEANUP_URL = os.environ.get("SUNOFLOW_CLEANUP_URL", "http://162.19.81.108:40009/cleanup")
ENTITLEMENT_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/entitlement"
# No default. A key used to ship here, identical in every install, which meant
# anyone who downloaded SunoFlow could use the gateway for free and it could not
# be revoked without breaking everyone. The device key now arrives per request
# from the app's Keychain; this remains only as a dev override.
CLEANUP_KEY = os.environ.get("SUNOFLOW_CLEANUP_KEY", "")

# Identifies this install to the gateway, as "<os>/<version>" — the only thing
# that makes a Windows-vs-Mac split possible in the product numbers, since the
# gateway otherwise sees two identical HTTP clients.
#
# Deliberately coarse. It is a platform name and a version string, not a machine
# fingerprint: no hostname, no serial, no username, nothing that identifies the
# device beyond the device key the request already carries.
#
# The version falls back to "dev" because the sidecar has no reliable way to know
# the app's version on its own — the app can pass SUNOFLOW_VERSION when it spawns
# the sidecar, and until it does, the OS half is still correct.
_CLIENT_OS = {"Darwin": "mac", "Windows": "windows", "Linux": "linux"}.get(
    platform.system(), "unknown"
)
CLIENT_ID = f"{_CLIENT_OS}/{os.environ.get('SUNOFLOW_VERSION', 'dev')}"

def _headers(key: str) -> dict:
    """Auth plus the client identity, on every gateway call."""
    return {"Authorization": f"Bearer {key}", "X-SunoFlow-Client": CLIENT_ID}



# One pooled connection to the gateway, kept warm across dictations.
#
# The module-level requests.post/get helpers build a throwaway Session per call,
# so every dictation paid for a DNS lookup, a TCP handshake and a TLS handshake
# before it could send its first byte — ~0.4s measured, sitting squarely between
# the user's last word and their pasted text.
#
# urllib3 checks a pooled connection before reusing it and dials a fresh one
# when the peer has closed it, so an idle gap between dictations is handled
# already. The single retry covers the rarer socket that dies without notice —
# a laptop that changed network since the last dictation. Both calls here are
# safe to repeat: the entitlement check is a plain read, and a cleanup POST that
# does arrive twice costs one extra gateway call and nothing else. Not retrying
# is the expensive option — it soft-fails the dictation to raw text, or refuses
# it outright on a device with no valid lease.
_ADAPTER = HTTPAdapter(max_retries=Retry(
    total=1, connect=1, read=1, status=0, allowed_methods=None, backoff_factor=0,
))
_session = requests.Session()
_session.mount("https://", _ADAPTER)
_session.mount("http://", _ADAPTER)  # dev/test point the URLs at plain HTTP

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
# In a distributed .app the bundled corrections.json (next to __file__) is
# read-only, so the frozen entry point (freeze_entry.py) overrides this with a
# writable copy in ~/Library/Application Support/SunoFlow/ via the env var.
CORRECTIONS_PATH = os.environ.get(
    "SUNOFLOW_CORRECTIONS_PATH",
    os.path.join(os.path.dirname(__file__), "corrections.json"),
)

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


KIND_CORRECTION = "correction"
KIND_EXPANSION = "expansion"

# What a "value" looks like: a URL, handle, email, bare domain, or phone number.
# These are the things a user saves so they never have to spell them out loud.
_VALUE_LIKE = re.compile(
    r"""(?xi)
      https?://
    | www\.
    | ^@[\w.]+$
    | [\w.+-]+@[\w-]+\.\w
    | \.(com|net|org|io|in|co|dev|me|ai|app|xyz)\b
    | ^\+?\d[\d\s().-]{7,}$
    """
)


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


def infer_kind(frm: str, to: str) -> str:
    """Classify an entry the user added without saying which kind it is.

    A correction is a re-spelling, so the two sides look alike; an expansion
    swaps a short spoken phrase for something structurally different and usually
    much longer. Errs toward a correction: that only ever changes a spelling,
    while an expansion inserts a personal value into the user's text.
    """
    to = to.strip()
    if _VALUE_LIKE.search(to):
        return KIND_EXPANSION
    if len(to) > max(24, len(frm) * 2):
        return KIND_EXPANSION
    if SequenceMatcher(None, _norm_key(frm), _norm_key(to)).ratio() < 0.5:
        return KIND_EXPANSION
    return KIND_CORRECTION


def _kind_of(entry: dict) -> str:
    """The stored kind, classifying on the fly for entries written before the
    field existed. Keeps an old corrections.json working with no migration."""
    kind = entry.get("kind")
    if kind in (KIND_CORRECTION, KIND_EXPANSION):
        return kind
    return infer_kind(entry.get("from", ""), entry.get("to", ""))


def _distinctive_tokens(s: str) -> list:
    """The words in ``s`` with enough signal to match a transcript on. "my
    Instagram" reduces to ["instagram"], so the entry is offered whether the
    user said "my Instagram ID", "my Instagram handle", or just "my Instagram".
    """
    return [
        t for t in (w.lower() for w in re.findall(r"\w+", s))
        if len(t) >= 3 and t not in _COMMON_WORDS
    ]


def _contains_phrase(lowered_text: str, phrase: str) -> bool:
    return re.search(r"(?<!\w)" + re.escape(phrase.lower()) + r"(?!\w)", lowered_text) is not None


def _entry(frm: str, to: str, count: int, kind: str = "") -> dict:
    frm, to = frm.strip(), to.strip()
    if kind not in (KIND_CORRECTION, KIND_EXPANSION):
        kind = infer_kind(frm, to)
    return {"from": frm, "to": to, "count": count, "kind": kind}


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
        # Always a correction: extract_correction_pairs only yields pairs whose
        # two sides look alike, which is what a mishearing is.
        entry["kind"] = KIND_CORRECTION
        corrections[key] = entry
        learned.append({"from": old, "to": new, "count": entry["count"]})
    if learned:
        _save_corrections(corrections)
    return learned


def apply_corrections(text: str) -> str:
    """Apply the *corrections* — longest-phrase-first, case-insensitive.

    Expansions are deliberately skipped. A blind global replace cannot tell
    "here's my Instagram" from "I don't have an Instagram", and getting that
    wrong drops the user's personal URL into a sentence that did not want it.
    The cleanup model decides those; see the DICTIONARY block in the gateway's
    system prompt.
    """
    if not corrections or not text:
        return text
    result = text
    entries = [v for v in corrections.values() if _kind_of(v) == KIND_CORRECTION]
    # Longer phrases first so multi-word fixes win over single-word ones.
    for entry in sorted(entries, key=lambda v: len(v["from"]), reverse=True):
        frm, to = entry["from"], entry["to"]
        # Lookarounds rather than \b: \b is a *transition*, so it silently fails
        # to match a "from" that starts or ends with punctuation. The replacement
        # is a function so that backslashes and \1-style sequences in the user's
        # text stay literal instead of being read as group references.
        result = re.sub(
            r"(?<!\w)" + re.escape(frm) + r"(?!\w)",
            lambda _m, to=to: to,
            result,
            flags=re.IGNORECASE,
        )
    return result


def relevant_corrections(text: str, limit: int = 40) -> list:
    """The entries worth sending to the cleanup model for this transcript.

    Filtering here rather than shipping the whole dictionary keeps the prompt
    small, and keeps every entry the user did not just say on this machine: a
    term only leaves when the transcript already looks like it.

    A correction has to appear literally — the mishearing *is* what the speech
    model produced. An expansion is matched on its distinctive words instead,
    since the spoken lead-in varies ("my Instagram ID", "my Instagram handle").
    """
    if not corrections or not text:
        return []
    lowered = text.lower()
    out = []
    for entry in corrections.values():
        frm, kind = entry["from"], _kind_of(entry)
        if kind == KIND_EXPANSION:
            tokens = _distinctive_tokens(frm)
            hit = (
                all(re.search(r"(?<!\w)" + re.escape(t), lowered) for t in tokens)
                if tokens
                else _contains_phrase(lowered, frm)
            )
        else:
            hit = _contains_phrase(lowered, frm)
        if hit:
            out.append({"from": frm, "to": entry["to"], "kind": kind,
                        "count": entry.get("count", 0)})
    # Expansions first, then most-used, so the cap sheds the entries least
    # likely to matter. Expansions are always count 0 — they are added by
    # hand, never learned — so sorting on count alone would drop exactly the
    # entries the user took the trouble to type in.
    out.sort(key=lambda e: (e["kind"] != KIND_EXPANSION, -e["count"], len(e["from"])))
    return [{"from": e["from"], "to": e["to"], "kind": e["kind"]} for e in out[:limit]]

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
        # Strip any URL from the surfaced error so the upstream model source
        # isn't leaked to the client UI. The full exception is kept in the log.
        safe = re.sub(r"https?://\S+", "[download URL]", str(exc))
        with _dl_lock:
            _dl_state.update(phase="error", active=False, error=safe)


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


# Statuses that mean "we reached the gateway and it refused us".
REFUSAL_STATUSES = (401, 402, 403)


class NotEntitled(Exception):
    """This device may not dictate: no account, or the account has lapsed.

    ``code`` distinguishes the reasons, because they are not the same thing to
    the user even though both stop the dictation. A lapsed subscription is fixed
    on the account page; an unreachable gateway is fixed by reconnecting to the
    internet. The app picks its wording from this rather than guessing from a
    402 alone.
    """

    def __init__(self, message: str, code: str = "not_entitled"):
        super().__init__(message)
        self.code = code



_DEFAULT_BLOCKED = "Your SunoFlow subscription isn't active. Open your account to continue."
_NOT_CONNECTED = "This device isn't connected to a SunoFlow account. Open Settings → Account to connect it."
_UNREACHABLE = (
    "SunoFlow couldn't reach the account service to check your subscription. "
    "Connect to the internet and try again."
)


def _refusal_message(resp) -> str:
    """The user-facing reason if this response is a refusal from us, else "".

    How a failed cleanup call is classified *is* the paywall, because that call
    is the only place a dictation is checked against the user's plan:

      * 2xx — entitled. Refresh the offline lease.
      * 401/402/403 with a JSON `error` body — our gateway refused this device:
        expired trial, lapsed subscription, disconnected device, unpaired
        install. Hard stop, every time. An expired account is meant to stop
        working, not to quietly downgrade to a free tier, and a 401 stops
        dictation exactly as a 402 does.
      * anything else — 429, 5xx, timeouts, DNS failures, a body that is not
        ours. Indistinguishable from an outage, so the stored lease decides.

    Requiring our JSON body is what stops an intermediary's own 401/403 page (a
    misconfigured proxy) from reading to the user as a cancelled subscription.
    """
    if resp.status_code not in REFUSAL_STATUSES:
        return ""
    try:
        body = resp.json()
    except Exception:
        return ""
    if not isinstance(body, dict) or "error" not in body:
        return ""
    return (body.get("message") or "").strip() or _DEFAULT_BLOCKED


def _allow_or_raise(key: str, why: str, quiet: bool = False) -> None:
    """Decide what an inconclusive gateway result means for this dictation.

    Falls back to the signed lease: a device that checked in recently keeps
    working through the outage, one that has not is refused. Returning normally
    means "carry on with the raw transcript".

    ``quiet`` silences the diagnostic print for the background refresh thread,
    which pokes the gateway after the caller has already returned and whose
    outage messages would otherwise noise up logs (and tests) for no benefit.
    """
    if lease.allows_offline(key):
        if not quiet:
            print(f"Cleanup gateway unavailable ({why}); continuing on a valid lease.")
        return
    if not quiet:
        print(f"Cleanup gateway unavailable ({why}) and no valid lease; refusing.")
    raise NotEntitled(_UNREACHABLE, code="unreachable")


# How long a successful live entitlement check authorizes the cleanup-off path
# to keep dictating without another blocking round trip. The on-disk lease is the
# real authority (72h); this cache is only the "skip the network call" grace, so
# a revoked account stops working within ~this many seconds, not 72h.
_ENTITLEMENT_CACHE_TTL = 600

# fingerprint(key) -> (last_check_monotonic, lease_path_at_check). The lease path
# is stored so the cache auto-invalidates when tests (or a relocated install)
# point lease.LEASE_PATH elsewhere — otherwise the module-level dict would leak
# "entitled" verdicts across configs that happen to share a key.
_entitlement_cache: dict[str, tuple[float, str]] = {}


def _check_entitlement_live(key: str, quiet: bool = False) -> None:
    """Perform the blocking GET to /entitlement and classify the result.

    On 2xx the signed lease is refreshed. On a refusal NotEntitled is raised. On
    anything inconclusive the lease decides via _allow_or_raise. ``quiet`` is
    forwarded to _allow_or_raise for the background refresh thread.
    """
    try:
        resp = _session.get(ENTITLEMENT_URL, headers=_headers(key), timeout=10)
    except Exception as exc:
        _allow_or_raise(key, str(exc), quiet=quiet)
        return

    message = _refusal_message(resp)
    if message:
        raise NotEntitled(message)
    if not resp.ok:
        _allow_or_raise(key, f"HTTP {resp.status_code}", quiet=quiet)
        return

    try:
        lease.save(resp.json().get("lease") or "", key)
    except Exception:
        pass


def _refresh_entitlement_in_background(key: str) -> None:
    """Best-effort, silent background refresh of the lease.

    Runs on a daemon thread, swallows every error (a failed refresh just leaves
    the previous lease in place until it lapses), and only records a cache hit
    on a genuine 2xx so a refusal or outage never extends the skip window.
    """

    def _run() -> None:
        try:
            _check_entitlement_live(key, quiet=True)
        except Exception:
            return
        # _check_entitlement_live returned normally → 2xx or a lease-covered
        # outage. Only a 2xx actually refreshed the lease; in both cases the
        # device is entitled right now, so the cache is valid.
        _entitlement_cache[lease.fingerprint(key)] = (time.monotonic(), lease.LEASE_PATH)

    threading.Thread(target=_run, name="sf-entitlement-refresh", daemon=True).start()


def check_entitlement(key: str) -> None:
    """Ask the gateway whether this device may dictate, without doing any work.

    Used when the cleanup pass is switched off — otherwise turning cleanup off
    would skip the only server call and hand out unlimited free dictation.

    To keep cleanup-off dictation from blocking STT on a remote round trip every
    time, a valid on-disk lease plus a recent successful check short-circuits the
    network call and refreshes the lease in the background. The first call (or
    one after the cache grace expires) still blocks, exactly as before.
    """
    key = key or CLEANUP_KEY
    if not key:
        raise NotEntitled(_NOT_CONNECTED, code="not_connected")

    fp = lease.fingerprint(key)
    cached = _entitlement_cache.get(fp)
    if (
        cached
        and cached[1] == lease.LEASE_PATH
        and (time.monotonic() - cached[0]) < _ENTITLEMENT_CACHE_TTL
        and lease.allows_offline(key)
    ):
        # Recent check + still-valid lease → trust it off the network and refresh
        # quietly in the background.
        _refresh_entitlement_in_background(key)
        return

    _check_entitlement_live(key)
    # Reached only on a 2xx (lease refreshed) or a lease-covered outage. Record
    # the cache so the next cleanup-off call within the grace window skips.
    _entitlement_cache[fp] = (time.monotonic(), lease.LEASE_PATH)


def clean_with_gateway(
    text: str,
    context: str = "",
    recent: list = None,
    screen: str = "",
    key: str = "",
    dictionary: list = None,
) -> str:
    """Clean a transcript via the hosted cleanup gateway.

    The gateway (cleanup-gateway/) owns the cleanup instruction, the LLM
    backend, and the echo-retry guard — so this is a single POST.

    `key` is this Mac's device key, sent by the app on every /transcribe call
    once the user has connected their account.

    `dictionary` is the slice of the user's own saved terms that looks relevant
    to *this* transcript (see relevant_corrections). corrections.json itself
    never leaves the Mac; these few entries ride along with the request so the
    model can fix the user's spellings and expand their shorthand, and the
    gateway neither stores nor logs them.

    Raises NotEntitled when the gateway refuses the device, or when it cannot be
    reached and no valid lease covers the gap. Every other failure soft-fails to
    the raw transcript, because a bad LLM response should never cost the user
    their words.
    """
    key = key or CLEANUP_KEY
    if not key:
        raise NotEntitled(_NOT_CONNECTED, code="not_connected")
    if not text.strip():
        return text

    recent = recent or []
    context = (context or "").strip()
    screen = (screen or "").strip()
    payload = {"text": text, "context": context, "recent": recent, "screen": screen}
    # Omitted rather than sent empty, so a request carries the user's terms only
    # when there were any to carry.
    if dictionary:
        payload["dictionary"] = dictionary

    try:
        resp = _session.post(
            CLEANUP_URL,
            headers=_headers(key),
            json=payload,
            timeout=60,
        )
    except Exception as exc:
        _allow_or_raise(key, str(exc))
        return text

    message = _refusal_message(resp)
    if message:
        raise NotEntitled(message)
    if not resp.ok:
        _allow_or_raise(key, f"HTTP {resp.status_code}")
        return text

    try:
        body = resp.json()
    except Exception as exc:
        # A 2xx we cannot parse is our own bug, not an entitlement question: the
        # gateway said yes, so keep the words and move on.
        print(f"Cleanup gateway returned an unreadable body: {exc}")
        return text

    lease.save(body.get("lease") or "", key)
    # Gateway already applies echo-retry, but guard against an empty payload
    # falling through — return raw rather than an empty string.
    return (body.get("cleaned") or "").strip() or text


class NotEntitledResponse(JSONResponse):
    """402 with the gateway's own wording, so the app can show it verbatim."""

    def __init__(self, message: str, code: str = "not_entitled"):
        super().__init__(status_code=402, content={"error": code, "message": message})


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    cleanup: bool = Query(True),
    context: str = Form(""),
    screen: str = Form(""),
    device_key: str = Header("", alias="X-SunoFlow-Device-Key"),
):
    key = device_key.removeprefix("Bearer ").strip()
    try:
        return await _transcribe_inner(file, cleanup, context, screen, key)
    except NotEntitled as exc:
        # Deliberately NOT a soft failure: an expired account stops working.
        print(f"Refusing dictation — {exc}")
        return NotEntitledResponse(str(exc), getattr(exc, "code", "not_entitled"))


async def _transcribe_inner(file, cleanup, context, screen, key):
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
        # Only the entries this transcript could plausibly need — the rest of the
        # dictionary stays on this Mac.
        relevant = relevant_corrections(raw_text)
        cleaned_text = await run_in_threadpool(
            clean_with_gateway, raw_text, context, list(recent_transcripts), screen,
            key, relevant,
        )
    else:
        # Cleanup off still has to prove entitlement, or switching it off would
        # be a free-dictation switch.
        await run_in_threadpool(check_entitlement, key)
        cleaned_text = raw_text

    # Apply the learned corrections as the final step so they always win over
    # whatever the models produced. Expansions are not applied here — they need
    # the model's judgement about whether the speaker was giving the value or
    # just mentioning the thing, so with cleanup off they simply do not fire.
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
        {"key": k, "from": v["from"], "to": v["to"], "count": v.get("count", 1),
         "kind": _kind_of(v)}
        for k, v in sorted(corrections.items())
    ]


@app.get("/corrections")
def get_corrections():
    return {"corrections": _corrections_list()}


@app.post("/corrections/add")
def add_correction(frm: str = Form(...), to: str = Form(...), kind: str = Form("")):
    """Manually add an entry (e.g. from the Settings UI).

    ``kind`` is optional — the UI does not ask, and an unset kind is inferred
    from the shape of the pair.
    """
    key = _norm_key(frm)
    if not key:
        return {"added": False, "corrections": _corrections_list()}
    # Preserve the count if the same key already existed.
    count = corrections.get(key, {}).get("count", 0)
    corrections[key] = _entry(frm, to, count, kind)
    _save_corrections(corrections)
    return {"added": True, "corrections": _corrections_list()}


@app.post("/corrections/update")
def update_correction(
    key: str = Form(...), frm: str = Form(...), to: str = Form(...), kind: str = Form("")
):
    """Edit an existing entry's from/to text."""
    old = corrections.pop(key, None)
    new_key = _norm_key(frm)
    if not new_key:
        # Restore the old entry if the new "from" is blank.
        if old is not None:
            corrections[key] = old
        return {"updated": False, "corrections": _corrections_list()}
    count = (old or {}).get("count", corrections.get(new_key, {}).get("count", 0))
    corrections[new_key] = _entry(frm, to, count, kind)
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
