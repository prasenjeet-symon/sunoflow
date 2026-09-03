# MIRROR of sidecars/shared/lease.py — do not edit one without the other.
#
# The macOS sidecar is still the single-file server.py (that is what release.sh
# freezes), so it cannot import from the sidecars/ package tree. The two copies
# are kept byte-identical below this header and a test asserts it, because the
# last time these trees drifted apart the Windows build shipped with no
# entitlement checking at all.
"""Offline entitlement leases — the sidecar half of the gateway's lease.go.

Cleanup soft-fails to the raw transcript whenever the gateway cannot be
reached, because an outage on our side must never cost a user their words.
Unbounded, that was the cheapest bypass in the product: blackhole
``cleanup.ogcode.xyz`` at the firewall and dictation is free forever, because
speech-to-text is local and nothing else breaks.

A lease bounds it. Every entitled response carries a signed token good for
``LEASE_TTL``; the sidecar stores it and, when the gateway is unreachable, keeps
working only while an unexpired one is on disk. Any real outage is invisible —
leases outlive it and every successful call mints a fresh one — and a host
that has been blocked on purpose stops working within three days.

The signature is HMAC-SHA256 and the verifying secret ships in this file, so a
determined user can unpack the sidecar and mint their own. That is the accepted
limit: this closes the bypass that costs nothing and spreads (editing a JSON
file), not the one that requires reverse-engineering, which patching the
sidecar would defeat anyway. The upgrade path is asymmetric signing — the
gateway keeps a private key and this module verifies with an embedded public
one — which changes only ``verify`` and needs a crypto dependency in the frozen
bundle.

The wire format is a cross-language contract with
``cleanup-gateway/internal/account/lease.go``. Both sides assert the same test
vector, so a change to one that is not mirrored in the other fails the build
instead of locking people out in the field.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time

# Must match account.DefaultLeaseSecret in the gateway. Not a real secret — see
# the module docstring. Overridable so a dev stack can run its own.
LEASE_SECRET = os.environ.get("SUNOFLOW_LEASE_SECRET", "sunoflow-lease-v1")

# Must match account.LeaseTTL. Only used for reporting; the authoritative expiry
# is the one the gateway signed into the token.
LEASE_TTL_SECONDS = 72 * 60 * 60


def _default_dir() -> str:
    """The app-owned, user-writable directory the lease lives in.

    Same convention as corrections.json on each platform, so a sidecar upgrade
    or reinstall does not silently drop the lease and lock someone out.
    """
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, "SunoFlow")


LEASE_PATH = os.environ.get("SUNOFLOW_LEASE_PATH") or os.path.join(_default_dir(), "lease.json")


def fingerprint(key: str) -> str:
    """The device identifier a lease carries: first 16 hex of SHA-256(key).

    Ties a lease to the key that earned it, so copying lease.json to another
    machine achieves nothing.
    """
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]


def _sign(encoded: str) -> str:
    return hmac.new(LEASE_SECRET.encode("utf-8"), encoded.encode("utf-8"), hashlib.sha256).hexdigest()


def verify(token: str, key: str, now: float = None) -> bool:
    """True iff ``token`` is a lease this gateway issued for ``key``, unexpired.

    Never raises: a malformed, truncated or hand-written lease is simply not
    valid, and the caller treats that the same as having none.
    """
    if not token or not key:
        return False
    now = time.time() if now is None else now
    try:
        encoded, _, signature = token.partition(".")
        if not signature:
            return False
        # compare_digest, not ==, so a wrong signature cannot be recovered one
        # byte at a time from response timings.
        if not hmac.compare_digest(signature, _sign(encoded)):
            return False
        padding = "=" * (-len(encoded) % 4)
        payload = json.loads(base64.urlsafe_b64decode(encoded + padding))
        if payload.get("kid") != fingerprint(key):
            return False
        return now < float(payload.get("exp", 0))
    except Exception:
        return False


def save(token: str, key: str, now: float = None) -> None:
    """Record a freshly issued lease. Best-effort: never fails a dictation.

    Verified before it is written, so a gateway (or a proxy in front of it)
    returning something unexpected cannot poison the file that decides offline
    access.
    """
    if not verify(token, key, now):
        return
    try:
        os.makedirs(os.path.dirname(LEASE_PATH), exist_ok=True)
        tmp = LEASE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"lease": token}, f)
        os.replace(tmp, LEASE_PATH)
    except Exception as exc:
        print(f"Could not store the entitlement lease: {exc}")


def load() -> str:
    try:
        with open(LEASE_PATH, encoding="utf-8") as f:
            return json.load(f).get("lease") or ""
    except Exception:
        return ""


def allows_offline(key: str, now: float = None) -> bool:
    """May this device dictate while the gateway is unreachable?"""
    return verify(load(), key, now)


def clear() -> None:
    """Drop the stored lease. Used by tests and when a device is re-paired."""
    try:
        os.remove(LEASE_PATH)
    except OSError:
        pass
