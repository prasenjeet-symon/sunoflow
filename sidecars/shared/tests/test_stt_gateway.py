"""Cloud STT client (the warm-start path) at the HTTP level.

``transcribe_with_gateway`` produces the raw transcript when the local model is
not yet available. It rides the SAME entitlement contract as /cleanup — cloud STT
is a paid feature on the same plan — so a refusal is a hard stop and an outage
defers to the signed lease. The one difference is the soft-fail target: there is
no raw text to keep (this call is what makes it), so a lease-covered outage
returns "" rather than falling back to a transcript that does not exist.

Run with ``pytest sidecars/shared/tests``. The macOS monolith carries its own
copy of this client; its parity is pinned in
``sidecar/tests/test_stt_parity.py`` against these same scenarios.
"""
import base64

import pytest

from sidecars.shared import cleanup, lease
from sidecars.shared.tests import gateway_stub

KEY = "sf_a_paired_device_key"
AUDIO = b"RIFF....fake wav bytes...."


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(cleanup, lease, monkeypatch, tmp_path)
    yield handle
    server.shutdown()
    server.server_close()


# --- happy path ---------------------------------------------------------------

def test_success_returns_transcript(gateway):
    gateway.replies(200, {"transcript": "hello world", "lease": gateway.issue_lease(KEY)})
    assert cleanup.transcribe_with_gateway(AUDIO, key=KEY) == "hello world"


def test_transcript_is_stripped(gateway):
    gateway.replies(200, {"transcript": "  spaced out  "})
    assert cleanup.transcribe_with_gateway(AUDIO, key=KEY) == "spaced out"


def test_audio_and_format_reach_the_wire(gateway):
    gateway.replies(200, {"transcript": "x"})
    cleanup.transcribe_with_gateway(AUDIO, key=KEY, fmt="wav")
    body = gateway.last_request()
    assert body is not None
    assert base64.b64decode(body["audio"]) == AUDIO
    assert body["format"] == "wav"


def test_language_sent_only_when_present(gateway):
    gateway.replies(200, {"transcript": "x"})
    cleanup.transcribe_with_gateway(AUDIO, key=KEY)
    assert "language" not in gateway.last_request()
    gateway.replies(200, {"transcript": "x"})
    cleanup.transcribe_with_gateway(AUDIO, key=KEY, language="en")
    assert gateway.last_request()["language"] == "en"


# --- guards -------------------------------------------------------------------

def test_no_key_is_not_connected(gateway):
    with pytest.raises(cleanup.NotEntitled) as exc:
        cleanup.transcribe_with_gateway(AUDIO, key="")
    assert exc.value.code == "not_connected"


def test_empty_audio_returns_empty_without_network(gateway):
    gateway.replies(500, {"error": "should not be reached"})
    assert cleanup.transcribe_with_gateway(b"", key=KEY) == ""
    assert gateway.last_request() is None  # never hit the wire


# --- refusals are a hard stop, same as cleanup --------------------------------

@pytest.mark.parametrize("status, error", [
    (402, "trial_expired"),
    (401, "revoked"),
    (403, "forbidden"),
])
def test_refusal_raises_not_entitled(gateway, status, error):
    gateway.replies(status, {"error": error, "message": "Nope."})
    with pytest.raises(cleanup.NotEntitled):
        cleanup.transcribe_with_gateway(AUDIO, key=KEY)


# --- outages defer to the lease, then soft-fail to "" -------------------------

def test_outage_with_valid_lease_returns_empty(gateway):
    # A recent lease covers the gap: no raw text exists to fall back to, so the
    # transcription is simply missed (empty), not refused.
    gateway.bank_lease(KEY)
    gateway.replies(503, {"error": "upstream"})
    assert cleanup.transcribe_with_gateway(AUDIO, key=KEY) == ""


def test_outage_without_lease_refuses(gateway):
    gateway.replies(503, {"error": "upstream"})
    with pytest.raises(cleanup.NotEntitled) as exc:
        cleanup.transcribe_with_gateway(AUDIO, key=KEY)
    assert exc.value.code == "unreachable"


def test_not_configured_501_is_treated_as_outage(gateway):
    # A gateway with no STT provider answers 501; indistinguishable from an
    # outage to the client, so the lease decides.
    gateway.bank_lease(KEY)
    gateway.replies(501, {"error": "unavailable"})
    assert cleanup.transcribe_with_gateway(AUDIO, key=KEY) == ""


def test_unreachable_host_with_lease_returns_empty(gateway):
    gateway.bank_lease(KEY)
    gateway.unreachable()
    # unreachable() only repoints cleanup/entitlement; steer STT at the dead port too.
    cleanup.STT_URL = "http://127.0.0.1:1/stt"
    assert cleanup.transcribe_with_gateway(AUDIO, key=KEY) == ""
