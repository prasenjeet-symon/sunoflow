"""Hosted Suno Answer: proxy the gateway's SSE answer stream to the app.

Suno Answer is a separate paid feature from cleanup (D6): the app dictates a
question, the gateway streams a grounded answer back as server-sent events.
The sidecar is a dumb proxy here — it selects dictionary entries relevant to
the query (D8: keyed on the question, not a transcript), forwards the request,
and pipes bytes through. No prompt building, no fallback, no retry: any failure
before the stream starts is passed to the app as the gateway's own JSON, and a
failure mid-stream rides the stream itself as an ``error`` event.

Wire contract (gateway -> sidecar -> app, byte-for-byte):

  meta    {"lease": "..."}          first event, always (lease refresh)
  delta   {"text": "..."}           one fragment of the answer
  sources {"domains":[...],"queries":N}
  done    {}                        clean end
  error   {"error":code,"message":"..."}  terminal, no fallback after it

Pre-stream failures are HTTP responses the proxy passes through verbatim:
  402 JSON {"error":..., "message":...}  -> app shows it like /transcribe's
  429 {"error":"limit"}                  -> app shows the limit card
  other 4xx/5xx {"error":"unavailable"}  -> app shows the unavailable card
"""
import base64
import json
import os

import requests
from requests.adapters import HTTPAdapter, Retry

from sidecars.shared.cleanup import (
    CLIENT_ID,
    NotEntitled,
    _headers,
    _refusal,
)

CLEANUP_URL = os.environ.get("SUNOFLOW_CLEANUP_URL", "https://cleanup.ogcode.xyz/cleanup")
ENTITLEMENT_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/entitlement"
# Dev-only key override, same posture as cleanup.py's CLEANUP_KEY: empty in
# production, the device key arrives per request from the app's Keychain.
CLEANUP_KEY = os.environ.get("SUNOFLOW_CLEANUP_KEY", "")

# Mirrors cleanup.py's CLEANUP_URL: same host, /answer path.
ANSWER_URL = os.environ.get("SUNOFLOW_ANSWER_URL", CLEANUP_URL.rsplit("/", 1)[0] + "/answer")

# Total ceiling on one answer turn. The gateway's own deadline is 90s (D3); the
# proxy waits slightly longer so the gateway's own timeout error event — which
# tells the user something kinder than a network error would — is what arrives.
ANSWER_TIMEOUT = 100.0

# One pooled connection to the gateway, shared with cleanup's session? No: a
# separate Session, deliberately. An SSE response holds its connection for the
# whole stream (up to ~90s); putting it in the same pool as cleanup's would
# block a dictation started while an answer is still streaming (A8 makes them
# mutually exclusive, but the two flows can still overlap in time), and the
# answer path must never queue behind an idle cleanup socket.
_adapter = HTTPAdapter(max_retries=Retry(
    total=0, connect=0, read=0, status=0, backoff_factor=0,
))
_session = requests.Session()
_session.mount("https://", _adapter)
_session.mount("http://", _adapter)

# Cheap gateway liveness endpoint on the answer session's own pool.
_GATEWAY_HEALTH_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/health"


def warm() -> None:
    """Keep the answer session's pooled connection warm.

    Because the answer path uses its OWN pool (above), the dictation keepalive in
    cleanup.py doesn't cover it, so the first Suno Answer after an idle spell
    would re-handshake to the gateway. `cleanup.keepalive_gateway` calls this on
    the same 2-minute schedule. Best-effort: every error is swallowed.
    """
    try:
        _session.get(_GATEWAY_HEALTH_URL, timeout=5)
    except Exception:
        pass

# Answer turns are capped like cleanup caps them, plus the dictionary cap the
# gateway re-checks anyway. The sidecar is the first line of defense: it drops
# rather than errors, so a pathological client cannot balloon the request.
MAX_QUERY_LEN = 2000
MAX_HISTORY_TURNS = 16
MAX_HISTORY_LEN = 4000
MAX_DICT_ENTRIES = 64
MAX_IMAGE_BYTES = 3 << 20


def stream_answer(query, history=None, image_bytes=None, key="", dictionary=None):
    """Generator of raw SSE byte chunks from the gateway.

    Raises NotEntitled when the gateway refuses the device (the caller turns
    that into the same 402 response /transcribe returns). Any other pre-stream
    failure returns an error-event generator — the HTTP response the app sees
    is still 200, carrying exactly one ``error`` event, because a streaming
    response has already been committed by the time a caller can tell.
    """
    if not key:
        raise NotEntitled(
            "This device isn't connected to a SunoFlow account. Open Settings → Account to connect it.",
            code="not_connected",
        )

    query = (query or "").strip()[:MAX_QUERY_LEN]
    if not query:
        raise ValueError("empty query")

    history = list(history or [])
    history = history[-MAX_HISTORY_TURNS:]
    turns = []
    for turn in history:
        q = (turn.get("q") or "").strip()[:MAX_HISTORY_LEN]
        a = (turn.get("a") or "").strip()[:MAX_HISTORY_LEN]
        if q or a:
            turns.append({"q": q, "a": a})

    dictionary = list(dictionary or [])[:MAX_DICT_ENTRIES]

    payload = {"query": query, "history": turns}
    if dictionary:
        payload["dictionary"] = dictionary
    if image_bytes:
        if len(image_bytes) > MAX_IMAGE_BYTES:
            raise ValueError("image too large")
        payload["image"] = base64.b64encode(image_bytes).decode("ascii")

    # Deliberately NO retry here (contrast cleanup's single-retry adapter):
    # a retried POST /answer would double-spend a paid message when the first
    # attempt reached the gateway but the connection died mid-stream.
    try:
        resp = _session.post(
            ANSWER_URL,
            headers=_headers(key),
            json=payload,
            stream=True,
            timeout=(10, ANSWER_TIMEOUT),
        )
    except Exception:
        # Network-level failure before any byte: not an entitlement question —
        # the request may never have arrived. The app gets a structured error
        # event rather than an exception, so its UI path is one code.
        return iter([_sse_bytes("error", {"error": "unavailable"})])

    refusal, code = _refusal(resp)
    if refusal:
        raise NotEntitled(refusal, code=code or "not_entitled")

    if resp.status_code == 429:
        # Retry-After=60 marks the daily allowance; =1 marks the per-minute
        # bucket, which is a "slow down", not a day over — different words.
        retry_after = resp.headers.get("Retry-After", "60")
        if retry_after.strip() == "1":
            return iter([_sse_bytes("error", {"error": "unavailable", "message": "Suno is answering as fast as it can — wait a few seconds and try again."})])
        return iter([_sse_bytes("error", {"error": "limit", "message": "You've used all your Suno Answers for today. They reset tomorrow."})])

    if not resp.ok:
        return iter([_sse_bytes("error", {"error": "unavailable", "message": "Suno Answer is unavailable right now. Try again shortly."})])

    # The lease rides the stream's first ``meta`` event, not a header, so there
    # is nothing to save here — the app-side SSE reader is what needs it, and
    # the gateway's meta event carries it to the client verbatim.
    return _pump(resp)


def _pump(resp):
    """Passthrough generator: yield gateway SSE bytes as they arrive."""
    try:
        for chunk in resp.iter_content(chunk_size=1024):
            if chunk:
                yield chunk
    finally:
        resp.close()


def _sse_bytes(event: str, payload: dict) -> bytes:
    """One SSE event frame, matching the gateway's framing."""
    return f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode("utf-8")