"""Hosted Suno Control: proxy the gateway's one-action planner to the app.

Suno Control is the agent loop: the user speaks a goal, the app screenshots
the screen, and the gateway plans EXACTLY ONE action (click, type, key, ...)
that the app executes before asking again. Unlike /answer this is a one-shot
JSON call per step — no SSE. The sidecar is a dumb proxy: it applies the
user's dictation corrections to the goal (a mis-heard goal drives a mis-heard
plan), selects dictionary entries relevant to it (the same ``relevant_for``
machinery as /transcribe), and forwards. No prompt building, no fallback, no
retry: the gateway's response JSON passes through verbatim, and failures come
back as structured JSON the app can act on.
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

# Mirrors cleanup.py's CLEANUP_URL: same host, /control path.
CONTROL_URL = os.environ.get("SUNOFLOW_CONTROL_URL", CLEANUP_URL.rsplit("/", 1)[0] + "/control")

# Dev-only key override, same posture as cleanup.py's CLEANUP_KEY: empty in
# production, the device key arrives per request from the app's Keychain.
CLEANUP_KEY = os.environ.get("SUNOFLOW_CLEANUP_KEY", "")

# Total ceiling on one planning step. The gateway's own deadline is 30s
# (CONTROL_TIMEOUT); the proxy waits slightly longer so the gateway's own
# error body — which says something kinder than a socket error would — is what
# arrives.
CONTROL_TIMEOUT = 35.0

# One pooled connection? No — a separate Session, deliberately (same posture
# as answer.py): a paid one-shot call must never queue behind or reuse cleanup's
# pooled socket, and its adapter carries NO retry (a retried POST /control
# would execute the same step twice when the first attempt reached the gateway
# but the connection died — worse than double-spend, because the second call's
# plan would execute on a screen the first call may already have changed).
_adapter = HTTPAdapter(max_retries=Retry(
    total=0, connect=0, read=0, status=0, backoff_factor=0,
))
_session = requests.Session()
_session.mount("https://", _adapter)
_session.mount("http://", _adapter)

# Caps mirroring the gateway's. The sidecar is the first line of defense: it
# drops rather than errors, so a pathological client cannot balloon the request.
MAX_GOAL_LEN = 2000
MAX_STEPS = 100
MAX_STEP_NOTE_LEN = 300
MAX_DICT_ENTRIES = 64
MAX_IMAGE_BYTES = 3 << 20

_NOT_CONNECTED = (
    "This device isn't connected to a SunoFlow account. "
    "Open Settings → Account to connect it."
)


def plan_action(goal, steps=None, image_bytes=None, context=None, key="", dictionary=None):
    """One planning step: POST to the gateway and return its JSON.

    Raises NotEntitled when the gateway refuses the device (the caller turns
    that into the same 402 response /transcribe returns). Raises ValueError on
    a bad goal/image from the app itself. On a limit, outage, or gateway
    502/4xx it returns {"error": ...} — the app's loop stops on anything that
    is not an action.
    """
    if not key:
        raise NotEntitled(_NOT_CONNECTED, code="not_connected")

    goal = (goal or "").strip()[:MAX_GOAL_LEN]
    if not goal:
        raise ValueError("empty goal")

    bounded = []
    for s in list(steps or []):
        if not isinstance(s, dict):
            continue
        action = str(s.get("action") or "").strip()[:32]
        if not action:
            continue
        bounded.append({"action": action, "note": str(s.get("note") or "").strip()[:MAX_STEP_NOTE_LEN]})
    bounded = bounded[-MAX_STEPS:]

    dictionary = list(dictionary or [])[:MAX_DICT_ENTRIES]

    payload = {
        "goal": goal,
        "steps": bounded,
        "context": context or {},
    }
    if dictionary:
        payload["dictionary"] = dictionary
    if image_bytes:
        if len(image_bytes) > MAX_IMAGE_BYTES:
            raise ValueError("image too large")
        payload["image"] = base64.b64encode(image_bytes).decode("ascii")

    # Deliberately NO retry (contrast cleanup's single-retry adapter) — see the
    # module docstring: a retried plan would double-execute on a changed screen.
    try:
        resp = _session.post(
            CONTROL_URL,
            headers=_headers(key),
            json=payload,
            timeout=(10, CONTROL_TIMEOUT),
        )
    except Exception:
        # Network-level failure before any byte: not an entitlement question —
        # the request may never have arrived. The loop stops cleanly.
        return {"error": "unavailable", "message": "Suno Control is unavailable right now. Try again shortly."}

    refusal, code = _refusal(resp)
    if refusal:
        raise NotEntitled(refusal, code=code or "not_entitled")

    if resp.status_code == 429:
        retry_after = resp.headers.get("Retry-After", "60")
        if retry_after.strip() == "1":
            return {
                "error": "limit",
                "message": "Suno Control is working as fast as it can — wait a few seconds and try again.",
                "retry_after": 1,
            }
        return {
            "error": "limit",
            "message": "You've used all your Suno Control for today. It resets tomorrow.",
            "retry_after": 60,
        }

    if resp.status_code == 502:
        # The gateway reached the planner and it failed to produce a valid
        # action: the loop stops rather than execute on a guess. A safety
        # block is distinct — the planner declined THIS goal, not the service —
        # so its code and message pass through verbatim and the app can say
        # "rephrase" instead of "outage".
        try:
            body = resp.json()
        except ValueError:
            body = {}
        if isinstance(body, dict) and body.get("error") == "safety_block":
            return {
                "error": "safety_block",
                "message": str(body.get("message") or "Suno Control's AI planner declined this goal. Try phrasing it differently."),
            }
        return {"error": "unavailable", "message": "Suno Control couldn't decide the next step. Try again shortly."}

    if not resp.ok:
        try:
            body = resp.json()
        except ValueError:
            body = {}
        if isinstance(body, dict) and body.get("error") == "safety_block":
            return {
                "error": "safety_block",
                "message": str(body.get("message") or "Suno Control's AI planner declined this goal. Try phrasing it differently."),
            }
        return {"error": "unavailable", "message": "Suno Control is unavailable right now. Try again shortly."}

    try:
        action = resp.json()
    except ValueError:
        return {"error": "unavailable", "message": "Suno Control is unavailable right now. Try again shortly."}

    if not isinstance(action, dict) or not action.get("action"):
        return {"error": "unavailable", "message": "Suno Control is unavailable right now. Try again shortly."}

    return action