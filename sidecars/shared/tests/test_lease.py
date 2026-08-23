"""Lease verification, including the wire format shared with the Go gateway.

The gateway signs leases and the sidecar verifies them, in two languages. The
vector below is the same one asserted in
``cleanup-gateway/internal/account/lease_test.go``; if either side changes its
encoding, both suites fail and the mismatch surfaces at build time rather than
as a field-wide lockout.
"""
import json
import os
import time

import pytest

from sidecars.shared import lease

# Produced by Go's SignLease("test-secret", sha256("sf_test_device_key"),
# "user-1", 2023-11-14T22:13:20Z, 72h).
VECTOR_SECRET = "test-secret"
VECTOR_KEY = "sf_test_device_key"
VECTOR_ISSUED = 1_700_000_000
VECTOR_TOKEN = (
    "eyJraWQiOiJiNDdlNzhiYTA5ZjNlY2E5IiwidWlkIjoidXNlci0xIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjE3MDAyNTkyMDB9"
    ".6d89be9115a017100035b2e4e721b8b8d0b3612a3b93c1c5a06e6a30c3430168"
)


@pytest.fixture
def signing_secret(monkeypatch):
    """Point the module at the vector's secret for the duration of a test."""
    monkeypatch.setattr(lease, "LEASE_SECRET", VECTOR_SECRET)


@pytest.fixture
def lease_file(tmp_path, monkeypatch):
    path = tmp_path / "lease.json"
    monkeypatch.setattr(lease, "LEASE_PATH", str(path))
    return path


def test_accepts_a_lease_the_gateway_signed(signing_secret):
    assert lease.verify(VECTOR_TOKEN, VECTOR_KEY, now=VECTOR_ISSUED + 60)


def test_fingerprint_matches_the_gateways_key_id(signing_secret):
    payload = json.loads(lease.base64.urlsafe_b64decode(VECTOR_TOKEN.split(".")[0] + "="))
    assert payload["kid"] == lease.fingerprint(VECTOR_KEY)


def test_expires_at_the_ttl(signing_secret):
    assert lease.verify(VECTOR_TOKEN, VECTOR_KEY, now=VECTOR_ISSUED + lease.LEASE_TTL_SECONDS - 1)
    assert not lease.verify(VECTOR_TOKEN, VECTOR_KEY, now=VECTOR_ISSUED + lease.LEASE_TTL_SECONDS + 1)


@pytest.mark.parametrize(
    "name, token, key",
    [
        ("another device's lease", VECTOR_TOKEN, "sf_a_different_device"),
        ("signature stripped", VECTOR_TOKEN.split(".")[0], VECTOR_KEY),
        ("signature altered", VECTOR_TOKEN[:-1] + ("0" if VECTOR_TOKEN[-1] != "0" else "1"), VECTOR_KEY),
        ("payload altered", "eyJraWQiOiJiNDdlNzhiYTA5ZjNlY2E5IiwiZXhwIjo5OTk5OTk5OTk5fQ." + VECTOR_TOKEN.split(".")[1], VECTOR_KEY),
        ("not a token", "hello", VECTOR_KEY),
        ("empty", "", VECTOR_KEY),
        ("no key", VECTOR_TOKEN, ""),
    ],
)
def test_rejects(signing_secret, name, token, key):
    assert not lease.verify(token, key, now=VECTOR_ISSUED + 60)


def test_a_hand_written_lease_file_does_not_grant_access(signing_secret, lease_file):
    """The bypass this whole mechanism exists to stop."""
    lease_file.write_text(json.dumps({"lease": "eyJraWQiOiJiNDdlNzhiYTA5ZjNlY2E5IiwiZXhwIjo5OTk5OTk5OTk5fQ.deadbeef"}))
    assert not lease.allows_offline(VECTOR_KEY)


def test_save_load_round_trip(signing_secret, lease_file):
    lease.save(VECTOR_TOKEN, VECTOR_KEY, now=VECTOR_ISSUED + 60)
    assert lease.load() == VECTOR_TOKEN
    assert lease.allows_offline(VECTOR_KEY, now=VECTOR_ISSUED + 60)


def test_save_refuses_to_store_an_unverifiable_lease(signing_secret, lease_file):
    """A gateway (or proxy) sending nonsense must not poison offline access."""
    lease.save("not-a-real-lease", VECTOR_KEY, now=VECTOR_ISSUED + 60)
    assert not lease_file.exists()
    assert lease.load() == ""


def test_missing_file_denies(signing_secret, lease_file):
    assert not lease.allows_offline(VECTOR_KEY)


def test_default_secret_matches_the_gateways(monkeypatch):
    """Both sides ship the same built-in, or no lease ever verifies in the wild."""
    monkeypatch.delenv("SUNOFLOW_LEASE_SECRET", raising=False)
    source = open(os.path.join(os.path.dirname(lease.__file__), "lease.py")).read()
    assert '"sunoflow-lease-v1"' in source


def test_ttl_matches_the_gateways():
    assert lease.LEASE_TTL_SECONDS == 72 * 60 * 60


def test_the_macos_sidecars_copy_has_not_drifted():
    """sidecar/lease.py is a hand-kept mirror; prove it is still identical.

    The macOS sidecar is frozen from the single-file sidecar/server.py and
    cannot import this package, so the module is duplicated. Silent drift
    between these two trees is exactly how the Windows build once shipped with
    no entitlement checking, so it is asserted rather than hoped for.
    """
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(lease.__file__))))
    mirror = os.path.join(root, "sidecar", "lease.py")
    body = open(mirror, encoding="utf-8").read()
    # Everything from the module docstring on must match byte for byte; only the
    # "# MIRROR of ..." header above it differs.
    start = body.index('"""')
    assert body[start:] == open(lease.__file__, encoding="utf-8").read()
