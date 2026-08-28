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
import threading
import time

import requests
from requests.adapters import HTTPAdapter, Retry

from sidecars.shared import lease

CLEANUP_URL = os.environ.get("SUNOFLOW_CLEANUP_URL", "http://162.19.81.108:40009/cleanup")
ENTITLEMENT_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/entitlement"

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
        resp = _session.get(ENTITLEMENT_URL, headers={"Authorization": f"Bearer {key}"}, timeout=10)
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
    """Verify the device may dictate, without doing any cleanup work.

    Used when the cleanup pass is off — otherwise switching it off would skip
    the only server call and hand out unlimited free dictation.

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
        resp = _session.post(
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
