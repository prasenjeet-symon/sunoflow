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
import base64
import os
import platform
import threading
import time

import requests
from requests.adapters import HTTPAdapter, Retry

from sidecars.shared import lease

CLEANUP_URL = os.environ.get("SUNOFLOW_CLEANUP_URL", "https://cleanup.ogcode.xyz/cleanup")
ENTITLEMENT_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/entitlement"
# Cloud speech-to-text (the warm-start dictation path). Same gateway host and
# auth as cleanup, its own endpoint. Override with SUNOFLOW_STT_URL for dev.
STT_URL = os.environ.get("SUNOFLOW_STT_URL", CLEANUP_URL.rsplit("/", 1)[0] + "/stt")
# Cheap gateway liveness endpoint, pinged periodically only to keep the pooled
# TLS connection warm (see keepalive_gateway).
GATEWAY_HEALTH_URL = CLEANUP_URL.rsplit("/", 1)[0] + "/health"

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


def keepalive_gateway() -> None:
    """Keep the pooled TLS connection to the gateway warm.

    urllib3 drops a pooled connection after ~300s idle, so a dictation after a
    quiet spell otherwise re-pays DNS + TCP + TLS (~0.4s, and much worse cold) on
    the critical path between the user's last word and their pasted text. A cheap
    /health ping every 2 minutes on the SAME session the dictation path uses
    holds the connection open. Best-effort: every error is swallowed. Meant to be
    run on a daemon thread started at sidecar startup.
    """
    while True:
        time.sleep(120)
        try:
            _session.get(GATEWAY_HEALTH_URL, timeout=5)
        except Exception:
            pass
        # The Suno Answer stream keeps its own pool (a 90s stream must never
        # queue behind an idle cleanup socket), so warm it too — otherwise the
        # first Answer after a quiet spell re-handshakes. Imported lazily:
        # answer imports cleanup, so a module-level import here would cycle.
        try:
            from . import answer as _answer
            _answer.warm()
        except Exception:
            pass
        # Suno Try-on does the same one-shot paid POST (and so the same idle
        # re-handshake), on its own pool. Same lazy import, same reason.
        try:
            from . import tryon as _tryon
            _tryon.warm()
        except Exception:
            pass

# No default. A key used to ship here, identical in every install, so anyone who
# downloaded SunoFlow could use the gateway for free and it could not be revoked
# without breaking everyone. The device key now arrives per request from the
# app's Keychain; this remains only as a dev override.
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


def _refusal(resp):
    """(message, code) for a refusal response, or ("", "") when not one.

    Companion to :func:`_refusal_message` for callers that must pass the
    gateway's own error token through verbatim (Suno Answer: the account sheet
    distinguishes "canceled" from "trial_expired" on the 402 it already knows
    how to render from /transcribe).
    """
    message = _refusal_message(resp)
    if not message:
        return "", ""
    try:
        body = resp.json()
        code = body.get("error") or ""
    except Exception:
        code = ""
    return message, code


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
    tone: str = "",
    app: str = "",
    app_site: str = "",
    app_detail: str = "",
    stt_source: str = "",
) -> str:
    """Clean a transcript via the hosted cleanup gateway.

    ``dictionary`` is the slice of the user's own saved terms that looks relevant
    to *this* transcript (see Corrections.relevant_for). The file itself never
    leaves the machine; these few entries ride along with the request so the
    model can fix the user's spellings and expand their shorthand, and the
    gateway neither stores nor logs them.

    ``app``, ``app_site`` and ``app_detail`` are what the OS said about where the
    dictation was going: the frontmost process's identifier, the host when that
    process is a browser, and the focused window's title. Like ``tone``, the IDs
    travel raw and the gateway owns every meaning attached to them — which app
    they name, which category it belongs to, and which of them is safe to count.
    Keeping that table in one place is the same call made for the tone list.

    ``tone`` is the ID of the writing voice the user picked — "formal", never the
    wording that produces formal output. The gateway owns the closed set and the
    instruction behind each entry, so nothing here validates the value: an ID it
    does not serve normalizes to the faithful default on its side. Keeping the
    list in one place is deliberate — three clients each carrying their own copy
    is how the entitlement check went missing from Windows.

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
    tone = (tone or "").strip()
    payload = {"text": text, "context": context, "recent": recent, "screen": screen}
    # Same reasoning as the dictionary below: a field is carried only when there
    # is something in it, so an older gateway and a client with nothing to say
    # both see the request they saw before.
    for field, value in (("app", app), ("app_site", app_site), ("app_detail", app_detail)):
        value = (value or "").strip()
        if value:
            payload[field] = value
    # Omitted rather than sent empty, so a gateway request carries the user's
    # terms only when there were any to carry.
    if dictionary:
        payload["dictionary"] = dictionary
    # Same reasoning, and it matters more here: with no tone chosen the request
    # must be exactly the one this sidecar sent before tones existed, so the
    # default path cannot have changed behaviour.
    if tone:
        payload["tone"] = tone
    # Which engine produced this transcript (analytics only): "local" | "cloud".
    # Omitted when unset so the request is unchanged for a caller that never sets
    # it; the gateway reports a missing value as "unknown".
    if stt_source:
        payload["stt_source"] = stt_source

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


def transcribe_with_gateway(
    audio: bytes,
    key: str = "",
    fmt: str = "wav",
    language: str = "",
) -> str:
    """Transcribe audio via the hosted cloud STT endpoint (the warm-start path).

    Used only while the local model is downloading (or being validated): the
    sidecar sends the same recording it would feed the local model and gets back
    a raw transcript, which then rides the normal cleanup pass exactly as a local
    transcript would.

    Entitlement is enforced here the same way it is for cleanup — cloud STT is a
    paid feature on the same subscription:

      * a refusal (401/402/403 with our JSON body) raises NotEntitled;
      * an outage (429/5xx/network) defers to the signed lease via
        _allow_or_raise, which refuses only when no valid lease covers it.

    The one difference from clean_with_gateway is the soft-fail target: there is
    no raw text to fall back to (this call *is* what produces it), so a
    lease-covered outage returns "" — an empty transcript the caller treats as a
    missed dictation (in shadow mode it falls back to the local result instead).
    """
    key = key or CLEANUP_KEY
    if not key:
        raise NotEntitled(_NOT_CONNECTED, code="not_connected")
    if not audio:
        return ""

    payload = {
        "audio": base64.b64encode(audio).decode("ascii"),
        "format": (fmt or "wav"),
    }
    if language:
        payload["language"] = language

    try:
        resp = _session.post(
            STT_URL,
            headers=_headers(key),
            json=payload,
            timeout=60,
        )
    except Exception as exc:
        _allow_or_raise(key, str(exc))
        return ""

    message = _refusal_message(resp)
    if message:
        raise NotEntitled(message)
    if not resp.ok:
        # Includes 501 (cloud STT not configured on this gateway): indistinguishable
        # from an outage to the caller, so the lease decides and we return empty.
        _allow_or_raise(key, f"HTTP {resp.status_code}")
        return ""

    try:
        body = resp.json()
    except Exception as exc:
        print(f"STT gateway returned an unreadable body: {exc}")
        return ""

    lease.save(body.get("lease") or "", key)
    # Diagnostic: the gateway reports which provider served the call and its own
    # gateway→provider time. Logged next to the sidecar's end-to-end cloud_stt_ms
    # so the difference isolates the sidecar↔gateway network overhead.
    prov, gms = body.get("provider"), body.get("stt_ms")
    if prov or gms is not None:
        print(f"[stt] provider={prov} gateway_stt_ms={gms}")
    return (body.get("transcript") or "").strip()
