"""The macOS sidecar must enforce exactly what the shared one does.

``sidecar/server.py`` is the single file release.sh freezes for macOS, and it
carries its own copy of the gateway logic rather than importing
``sidecars/shared``. That duplication is real and, for now, deliberate — but it
is also how the Windows build once ended up with no entitlement checking at all.
So the same scenarios run here, against the macOS copy, using the same harness.

Skipped where parakeet-mlx is not installed (server.py imports it at module
level), which is every non-Mac checkout.
"""
import os
import sys

import pytest

from sidecars.shared.tests import gateway_stub

pytest.importorskip("parakeet_mlx", reason="macOS sidecar deps not installed")

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
import lease as mac_lease   # noqa: E402  — sidecar/lease.py, the mirrored copy
import server as mac        # noqa: E402  — sidecar/server.py

KEY = "sf_a_paired_device_key"


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(mac, mac_lease, monkeypatch, tmp_path)
    yield handle
    server.shutdown()
    server.server_close()


def both_paths():
    return gateway_stub.verdicts(mac, KEY)


@pytest.mark.parametrize("status, error", [
    (402, "trial_expired"),
    (401, "revoked"),
    (401, "invalid_key"),
    (403, "forbidden"),
])
def test_a_refusal_blocks_on_both_paths(gateway, status, error):
    gateway.replies(status, {"error": error, "message": "Nope."})
    assert both_paths() == {
        "cleanup_on": "blocked:not_entitled",
        "cleanup_off": "blocked:not_entitled",
    }


def test_unreachable_without_a_lease_is_refused(gateway):
    gateway.unreachable()
    assert both_paths() == {
        "cleanup_on": "blocked:unreachable",
        "cleanup_off": "blocked:unreachable",
    }


def test_unreachable_with_a_valid_lease_keeps_working(gateway):
    gateway.bank_lease(KEY)
    gateway.unreachable()
    assert both_paths() == {"cleanup_on": "served", "cleanup_off": "served"}


def test_an_expired_lease_does_not_keep_working(gateway):
    gateway.bank_lease(KEY, ttl=-60)
    gateway.unreachable()
    assert both_paths() == {
        "cleanup_on": "blocked:unreachable",
        "cleanup_off": "blocked:unreachable",
    }


def test_an_unconnected_device_is_refused(gateway):
    assert gateway_stub.verdicts(mac, "") == {
        "cleanup_on": "blocked:not_connected",
        "cleanup_off": "blocked:not_connected",
    }


def test_an_entitled_call_banks_its_lease(gateway):
    token = gateway.issue_lease(KEY)
    gateway.replies(200, {"cleaned": "Hello world.", "lease": token})
    assert mac.clean_with_gateway("hello world", key=KEY) == "Hello world."
    assert mac_lease.load() == token


def test_cleanup_off_skips_the_network_call_when_a_recent_check_cached(gateway, monkeypatch):
    """A valid lease plus a recent successful entitlement check must short-circuit
    the cleanup-off round trip — the whole point of the cache. The second call
    makes no live HTTP request to /entitlement and still returns entitled."""
    # First call: live check against the stub, banks a lease, primes the cache.
    token = gateway.issue_lease(KEY)
    gateway.replies(200, {"ok": True, "lease": token})
    mac.check_entitlement(KEY)
    assert mac_lease.load() == token

    # Turn the gateway into a refusal. Without the cache, the next cleanup-off
    # call would hit the stub and be blocked. With the cache it must stay served.
    gateway.replies(402, {"error": "trial_expired", "message": "Nope."})
    mac.check_entitlement(KEY)  # must NOT raise — cache short-circuits


def test_the_cache_does_not_extend_a_refusal(gateway):
    """A refused account never banks a cache entry, so the next call is still a
    live check — the cache cannot turn a refusal into free dictation."""
    gateway.replies(402, {"error": "trial_expired", "message": "Nope."})
    with pytest.raises(mac.NotEntitled):
        mac.check_entitlement(KEY)
    # Second call must also refuse (no cache hit from the first).
    with pytest.raises(mac.NotEntitled):
        mac.check_entitlement(KEY)


def test_an_expired_lease_is_not_rescued_by_the_cache(gateway, monkeypatch):
    """A cache entry is only usable while the on-disk lease is still valid. Once
    the lease lapses, the cache must miss and the call must go live again."""
    # Prime: live check banks a lease and primes the cache.
    token = gateway.issue_lease(KEY)
    gateway.replies(200, {"ok": True, "lease": token})
    mac.check_entitlement(KEY)

    # Expire the lease on disk, then make the gateway unreachable.
    gateway.bank_lease(KEY, ttl=-60)
    gateway.unreachable()

    # The cache entry exists but the lease is invalid, so it must miss and the
    # live check must run → unreachable → blocked.
    with pytest.raises(mac.NotEntitled) as exc:
        mac.check_entitlement(KEY)
    assert exc.value.code == "unreachable"


# --- the route, not just the helpers -----------------------------------------
#
# The tests above call the gateway helpers directly. That is not enough: a live
# probe of the installed sidecar caught `/transcribe` raising NameError on the
# cleanup=true path — the route called `clean_with_gateway` while the function
# was still named `clean_with_ollama`, and nothing here went through the route
# to notice. These do.

import io                      # noqa: E402
import struct                  # noqa: E402
import wave                    # noqa: E402

from fastapi.testclient import TestClient   # noqa: E402


class _FakeResult:
    text = "hello world"


class _FakeModel:
    def transcribe(self, path):
        return _FakeResult()


def _wav_bytes(seconds=1.0, rate=16000):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<h", 0) * int(rate * seconds))
    return buf.getvalue()


@pytest.fixture
def route(gateway, monkeypatch, request):
    """The real /transcribe route, with STT stubbed and the stub gateway wired."""
    monkeypatch.setattr(mac, "model", _FakeModel())
    client = TestClient(mac.app)
    # Closed in teardown: each TestClient holds a blocking portal, and leaking
    # one per test eventually starves the suite.
    request.addfinalizer(client.close)

    def post(cleanup=True, key=KEY):
        headers = {"X-SunoFlow-Device-Key": f"Bearer {key}"} if key is not None else {}
        return client.post(
            f"/transcribe?cleanup={'true' if cleanup else 'false'}",
            files={"file": ("audio.wav", _wav_bytes(), "audio/wav")},
            data={"context": "", "screen": ""},
            headers=headers,
        )

    return post


@pytest.mark.parametrize("cleanup_on", [True, False])
def test_the_route_serves_an_entitled_dictation(route, gateway, cleanup_on):
    """The regression: cleanup=true 500'd while cleanup=false was fine."""
    gateway.replies(200, {"cleaned": "Hello world.", "lease": gateway.issue_lease(KEY)})
    resp = route(cleanup=cleanup_on)
    assert resp.status_code == 200, resp.text
    assert resp.json()["raw"] == "hello world"
    assert resp.json()["cleaned"] == ("Hello world." if cleanup_on else "hello world")


@pytest.mark.parametrize("cleanup_on", [True, False])
def test_the_route_refuses_a_lapsed_account(route, gateway, cleanup_on):
    gateway.replies(402, {"error": "trial_expired", "message": "Your free trial has ended."})
    resp = route(cleanup=cleanup_on)
    assert resp.status_code == 402
    assert resp.json() == {"error": "not_entitled", "message": "Your free trial has ended."}


@pytest.mark.parametrize("cleanup_on", [True, False])
def test_the_route_refuses_a_revoked_device(route, gateway, cleanup_on):
    gateway.replies(401, {"error": "revoked", "message": "This device was disconnected."})
    assert route(cleanup=cleanup_on).status_code == 402


@pytest.mark.parametrize("cleanup_on", [True, False])
def test_the_route_refuses_an_unpaired_install(route, cleanup_on):
    resp = route(cleanup=cleanup_on, key=None)
    assert resp.status_code == 402
    assert resp.json()["error"] == "not_connected"


# --- the personal dictionary must behave identically in both copies -----------

from sidecars.shared.corrections import Corrections  # noqa: E402
from sidecars.shared import corrections as shared_corrections  # noqa: E402

# from, to, and a sentence to run them against.
DICTIONARY_CASES = [
    ("cavach", "Kavach", "the cavach system is live"),
    ("jon", "John", "I saw jon today"),
    ("sunno flow", "SunoFlow", "I use sunno flow daily"),
    ("my Instagram", "https://instagram.com/someone", "here is my Instagram ID"),
    ("my email", "someone@example.com", "my email if you need it"),
    ("my handle", "@someone", "my handle is that one"),
    ("my site", "www.example.com", "check my site later"),
    ("my number", "+91 98765 43210", "my number is written down"),
]


@pytest.mark.parametrize("frm, to, said", DICTIONARY_CASES)
def test_the_two_copies_classify_and_apply_identically(frm, to, said, tmp_path, monkeypatch):
    """The macOS copy of the dictionary logic must not drift from the shared one.

    Classification decides whether an entry is applied blindly or handed to the
    model to judge — so a disagreement here means one platform silently pastes a
    personal URL where the other correctly leaves the words alone.
    """
    shared = Corrections(str(tmp_path / "corrections.json"))
    shared.add(frm, to)

    monkeypatch.setattr(mac, "corrections", {mac._norm_key(frm): mac._entry(frm, to, 0)})

    assert mac.infer_kind(frm, to) == shared_corrections.infer_kind(frm, to)
    assert mac.apply_corrections(said) == shared.apply(said)
    assert mac.relevant_corrections(said) == shared.relevant_for(said)


def test_the_macos_sidecar_sends_the_dictionary(gateway):
    entries = [{"from": "cavach", "to": "Kavach", "kind": "correction"}]
    mac.clean_with_gateway("the cavach system", key=KEY, dictionary=entries)
    assert gateway.last_request()["dictionary"] == entries


def test_the_macos_sidecar_omits_an_empty_dictionary(gateway):
    mac.clean_with_gateway("hello world", key=KEY, dictionary=[])
    assert "dictionary" not in gateway.last_request()


# --- the connection is kept, not rebuilt per dictation ------------------------

def test_dictations_share_one_connection(gateway, monkeypatch):
    """Dictation is a latency product: a new DNS lookup and TCP/TLS handshake per
    call is ~0.4s the user spends staring at an empty cursor, for nothing."""
    connections = gateway_stub.count_connections(monkeypatch)
    for _ in range(3):
        mac.clean_with_gateway("hello world", key=KEY)
    assert connections.count == 1


def test_the_entitlement_check_shares_that_connection(gateway, monkeypatch):
    """Cleanup-off dictation goes to the same host and must not dial its own."""
    gateway.replies(200, {"cleaned": "Hello world.", "lease": gateway.issue_lease(KEY)})
    connections = gateway_stub.count_connections(monkeypatch)
    mac.clean_with_gateway("hello world", key=KEY)
    mac.check_entitlement(KEY)
    assert connections.count == 1
