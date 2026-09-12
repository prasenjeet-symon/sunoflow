"""Hosted Suno Try-on: proxy the gateway's virtual try-on to the app.

Suno Try-on is the paid image feature: the user keeps a photo of themselves on
file, speaks what to try on ("the green linen shirt"), and the gateway's image
model returns a photo of them wearing it. Unlike /answer this is a one-shot
JSON call — no SSE — and unlike /control the payload carries TWO images: the
person photo and the garment shot (this turn's screenshot). The sidecar is a
dumb proxy: it applies the user's dictation corrections to the item name, selects
dictionary entries relevant to it (the same ``relevant_for`` machinery as
/transcribe), and forwards. No prompt building, no fallback, no retry: the
gateway's response JSON passes through verbatim, and failures come back as
structured JSON the app can act on.

The images are the person's own likeness, so the payload never touches disk
here — bytes arrive per request from the app and are base64'd straight into the
gateway body.
"""
import base64
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

# Mirrors cleanup.py's CLEANUP_URL: same host, /tryon path.
TRYON_URL = os.environ.get("SUNOFLOW_TRYON_URL", CLEANUP_URL.rsplit("/", 1)[0] + "/tryon")

# Dev-only key override, same posture as cleanup.py's CLEANUP_KEY: empty in
# production, the device key arrives per request from the app's Keychain.
CLEANUP_KEY = os.environ.get("SUNOFLOW_CLEANUP_KEY", "")

# Total ceiling on one generation. The gateway's own deadline is 50s
# (TRYON_TIMEOUT); the proxy waits slightly longer so the gateway's own error
# body — which says something kinder than a socket error would — is what
# arrives.
TRYON_TIMEOUT = 55.0

# Cheap gateway liveness endpoint on the try-on session's own pool.
_GATEWAY_HEALTH_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/health"


def warm() -> None:
    """Keep the try-on session's pooled connection warm.

    Because the try-on path uses its OWN pool (below), the dictation keepalive
    in cleanup.py doesn't cover it, so the first Suno Try-on after an idle spell
    would re-handshake to the gateway. `cleanup.keepalive_gateway` calls this on
    the same 2-minute schedule. Best-effort: every error is swallowed.
    """
    try:
        _session.get(_GATEWAY_HEALTH_URL, timeout=5)
    except Exception:
        pass


# One pooled connection shared with cleanup's? No — a separate Session,
# deliberately (same posture as answer.py and control.py): a paid one-shot call
# must never queue behind or reuse cleanup's pooled socket, and its adapter
# carries NO retry. A retried POST /tryon would double-spend quota (the daily
# allowance is tiny) for a garment render the user may never see.
_adapter = HTTPAdapter(max_retries=Retry(
    total=0, connect=0, read=0, status=0, backoff_factor=0,
))
_session = requests.Session()
_session.mount("https://", _adapter)
_session.mount("http://", _adapter)

# Caps mirroring the gateway's. The sidecar is the first line of defense: it
# drops rather than errors, so a pathological client cannot balloon the request.
MAX_ITEM_LEN = 500
MAX_QUERY_LEN = 2000
MAX_APP_LEN = 120
MAX_WINDOW_LEN = 300
MAX_DICT_ENTRIES = 64
MAX_IMAGE_BYTES = 3 << 20

_NOT_CONNECTED = (
    "This device isn't connected to a SunoFlow account. "
    "Open Settings → Account to connect it."
)


def generate_tryon(item, query="", person_bytes=None, garment_bytes=None,
                   context=None, key="", dictionary=None):
    """One generation: POST to the gateway and return its JSON.

    Raises NotEntitled when the gateway refuses the device (the caller turns
    that into the same 402 response /transcribe returns). Raises ValueError on
    a bad item/images from the app itself. On a limit, outage, or gateway
    502/4xx it returns {"error": ...} — the app's UI stops on anything that is
    not an image.
    """
    if not key:
        raise NotEntitled(_NOT_CONNECTED, code="not_connected")

    item = (item or "").strip()[:MAX_ITEM_LEN]
    if not item:
        raise ValueError("empty item")
    if not person_bytes:
        raise ValueError("missing person photo")
    if not garment_bytes:
        raise ValueError("missing garment image")
    if len(person_bytes) > MAX_IMAGE_BYTES or len(garment_bytes) > MAX_IMAGE_BYTES:
        raise ValueError("image too large")

    dictionary = list(dictionary or [])[:MAX_DICT_ENTRIES]

    context = context or {}
    payload = {
        "item": item,
        "query": (query or "").strip()[:MAX_QUERY_LEN],
        "context": {
            "app": str(context.get("app") or "").strip()[:MAX_APP_LEN],
            "window": str(context.get("window") or "").strip()[:MAX_WINDOW_LEN],
        },
        "person": base64.b64encode(person_bytes).decode("ascii"),
        "garment": base64.b64encode(garment_bytes).decode("ascii"),
    }
    if dictionary:
        payload["dictionary"] = dictionary

    # Deliberately NO retry (contrast cleanup's single-retry adapter) — see the
    # module docstring: a retried generation would double-spend quota.
    try:
        resp = _session.post(
            TRYON_URL,
            headers=_headers(key),
            json=payload,
            timeout=(10, TRYON_TIMEOUT),
        )
    except Exception:
        # Network-level failure before any byte: not an entitlement question —
        # the request may never have arrived. The UI gets a structured error
        # rather than an exception, so its path is one code.
        return {"error": "unavailable", "message": "Suno Try-on is unavailable right now. Try again shortly."}

    refusal, code = _refusal(resp)
    if refusal:
        raise NotEntitled(refusal, code=code or "not_entitled")

    if resp.status_code == 429:
        retry_after = resp.headers.get("Retry-After", "60")
        if retry_after.strip() == "1":
            return {
                "error": "limit",
                "message": "Suno Try-on is working as fast as it can — wait a few seconds and try again.",
                "retry_after": 1,
            }
        return {
            "error": "limit",
            "message": "You've used all your Suno Try-ons for today. They reset tomorrow.",
            "retry_after": 60,
        }

    if resp.status_code == 502:
        # The gateway reached the image model and it failed to produce an image:
        # the UI stops rather than show a guess. A safety block is distinct —
        # the model declined THIS request, not the service — so its code and
        # message pass through verbatim and the app can say "rephrase" instead
        # of "outage".
        try:
            body = resp.json()
        except ValueError:
            body = {}
        if isinstance(body, dict) and body.get("error") == "safety_block":
            return {
                "error": "safety_block",
                "message": str(body.get("message") or "Suno Try-on declined this request. Try phrasing it differently."),
            }
        return {"error": "unavailable", "message": "Suno Try-on couldn't generate that. Try again shortly."}

    if not resp.ok:
        try:
            body = resp.json()
        except ValueError:
            body = {}
        if isinstance(body, dict) and body.get("error") == "safety_block":
            return {
                "error": "safety_block",
                "message": str(body.get("message") or "Suno Try-on declined this request. Try phrasing it differently."),
            }
        return {"error": "unavailable", "message": "Suno Try-on is unavailable right now. Try again shortly."}

    try:
        result = resp.json()
    except ValueError:
        return {"error": "unavailable", "message": "Suno Try-on is unavailable right now. Try again shortly."}

    # The gateway's success body is {"image": b64, "mime_type": ...} (plus a
    # lease field when the account middleware minted one). Anything without an
    # image is not a success — pass through the gateway's own body when it is
    # already an error envelope, else the generic unavailable.
    if not isinstance(result, dict) or not result.get("image"):
        if isinstance(result, dict) and result.get("error"):
            return result
        return {"error": "unavailable", "message": "Suno Try-on is unavailable right now. Try again shortly."}

    return result