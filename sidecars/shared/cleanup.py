"""Hosted cleanup-gateway calls, and the entitlement decision that rides on them.

Cleanup/LLM does not run locally. The sidecar POSTs the transcript to a remote
cleanup gateway (Go service, see cleanup-gateway/) which owns the cleanup
instruction, the LLM backend (Gemini), and the echo-retry guard.

That one call is also the only place a dictation is checked against the user's
trial or subscription, so how its failures are classified *is* the paywall:

  * **2xx** — entitled. Refresh the offline lease and use the cleaned text.
  * **401 / 402 / 403 carrying a JSON `error`** — a refusal from our gateway:
    expired trial, lapsed subscription, disconnected device, unpaired install.
    Always a hard stop — raise NotEntitled and paste nothing. An expired account
    is meant to stop working, not to quietly downgrade to a free tier, and 401
    stops dictation exactly as 402 does. (Requiring our JSON body is what keeps
    an intermediary's own 401/403 page — a misconfigured proxy — from reading to
    the user as a cancelled subscription.)
  * **anything else** — 429, 5xx, timeouts, DNS failures, a body that isn't
    ours. Entitled and not-entitled are indistinguishable here, so the stored
    lease decides: keep working while one is valid, refuse once it lapses.
    See lease.py.

Override SUNOFLOW_CLEANUP_URL / SUNOFLOW_CLEANUP_KEY for dev (e.g. point at a
local docker-compose stack).
"""
import os

import requests

from sidecars.shared import lease

CLEANUP_URL = os.environ.get("SUNOFLOW_CLEANUP_URL", "https://cleanup.mirrorli.art/cleanup")
ENTITLEMENT_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/entitlement"

# No default. A key used to ship here, identical in every install, so anyone who
# downloaded SunoFlow could use the gateway for free and it could not be revoked
# without breaking everyone. The device key now arrives per request from the
# app's Keychain; this remains only as a dev override.
CLEANUP_KEY = os.environ.get("SUNOFLOW_CLEANUP_KEY", "")

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
    """The user-facing reason if this response is a refusal, else "".

    A refusal is a 401/402/403 whose body is JSON from our gateway. Anything
    else carrying those statuses came from something in between and is treated
    as an outage, not as a cancelled subscription.
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


def _allow_or_raise(key: str, why: str) -> None:
    """Decide what an inconclusive gateway result means for this dictation.

    Falls back to the signed lease: a device that checked in recently keeps
    working through the outage, one that has not is refused. Returning normally
    means "carry on with the raw transcript".
    """
    if lease.allows_offline(key):
        print(f"Cleanup gateway unavailable ({why}); continuing on a valid lease.")
        return
    print(f"Cleanup gateway unavailable ({why}) and no valid lease; refusing.")
    raise NotEntitled(_UNREACHABLE, code="unreachable")


def check_entitlement(key: str) -> None:
    """Verify the device may dictate, without doing any cleanup work.

    Used when the cleanup pass is off — otherwise switching it off would skip
    the only server call and hand out unlimited free dictation.
    """
    key = key or CLEANUP_KEY
    if not key:
        raise NotEntitled(_NOT_CONNECTED, code="not_connected")

    try:
        resp = requests.get(ENTITLEMENT_URL, headers={"Authorization": f"Bearer {key}"}, timeout=10)
    except Exception as exc:
        _allow_or_raise(key, str(exc))
        return

    message = _refusal_message(resp)
    if message:
        raise NotEntitled(message)
    if not resp.ok:
        _allow_or_raise(key, f"HTTP {resp.status_code}")
        return

    try:
        lease.save(resp.json().get("lease") or "", key)
    except Exception:
        pass


def clean_with_gateway(
    text: str,
    context: str = "",
    recent: list = None,
    screen: str = "",
    key: str = "",
    dictionary: list = None,
) -> str:
    """Clean a transcript via the hosted cleanup gateway.

    ``dictionary`` is the slice of the user's own saved terms that looks relevant
    to *this* transcript (see Corrections.relevant_for). The file itself never
    leaves the machine; these few entries ride along with the request so the
    model can fix the user's spellings and expand their shorthand, and the
    gateway neither stores nor logs them.

    Raises NotEntitled when the gateway refuses the device, or when it cannot be
    reached and no valid lease covers the gap. Every other failure soft-fails to
    the raw transcript, so a bad LLM response never costs the user their words.
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
    # Omitted rather than sent empty, so a gateway request carries the user's
    # terms only when there were any to carry.
    if dictionary:
        payload["dictionary"] = dictionary

    try:
        resp = requests.post(
            CLEANUP_URL,
            headers={"Authorization": f"Bearer {key}"},
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
