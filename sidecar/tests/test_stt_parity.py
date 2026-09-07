"""The macOS sidecar's cloud-STT client must match the shared one.

``sidecar/server.py`` carries its own copy of transcribe_with_gateway and the
warm-start wiring rather than importing ``sidecars/shared``. That duplication is
deliberate (the frozen macOS build bundles only ``sidecar/``) but it is exactly
how Windows once shipped with no entitlement checking — so the same scenarios
that pin the shared client in ``sidecars/shared/tests/test_stt_gateway.py`` run
here against the macOS copy.

Skipped where parakeet-mlx is not installed (server.py imports it at module
level), which is every non-Mac checkout.
"""
import base64
import io
import os
import struct
import sys
import wave

import pytest

from sidecars.shared.tests import gateway_stub

pytest.importorskip("parakeet_mlx", reason="macOS sidecar deps not installed")

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
import lease as mac_lease   # noqa: E402  — sidecar/lease.py, the mirrored copy
import server as mac        # noqa: E402  — sidecar/server.py
import warmstart as mac_warmstart  # noqa: E402  — sidecar/warmstart.py

KEY = "sf_a_paired_device_key"
AUDIO = b"RIFF....fake wav bytes...."


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(mac, mac_lease, monkeypatch, tmp_path)
    yield handle
    server.shutdown()
    server.server_close()


# --- client-level parity with the shared copy ---------------------------------

def test_success_returns_transcript(gateway):
    gateway.replies(200, {"transcript": "hello world", "lease": gateway.issue_lease(KEY)})
    assert mac.transcribe_with_gateway(AUDIO, key=KEY) == "hello world"


def test_audio_and_format_reach_the_wire(gateway):
    gateway.replies(200, {"transcript": "x"})
    mac.transcribe_with_gateway(AUDIO, key=KEY, fmt="wav")
    body = gateway.last_request()
    assert base64.b64decode(body["audio"]) == AUDIO
    assert body["format"] == "wav"


def test_no_key_is_not_connected(gateway):
    with pytest.raises(mac.NotEntitled) as exc:
        mac.transcribe_with_gateway(AUDIO, key="")
    assert exc.value.code == "not_connected"


def test_empty_audio_returns_empty_without_network(gateway):
    gateway.replies(500, {"error": "should not be reached"})
    assert mac.transcribe_with_gateway(b"", key=KEY) == ""
    assert gateway.last_request() is None


@pytest.mark.parametrize("status, error", [(402, "trial_expired"), (401, "revoked"), (403, "forbidden")])
def test_refusal_raises_not_entitled(gateway, status, error):
    gateway.replies(status, {"error": error, "message": "Nope."})
    with pytest.raises(mac.NotEntitled):
        mac.transcribe_with_gateway(AUDIO, key=KEY)


def test_outage_with_valid_lease_returns_empty(gateway):
    gateway.bank_lease(KEY)
    gateway.replies(503, {"error": "upstream"})
    assert mac.transcribe_with_gateway(AUDIO, key=KEY) == ""


def test_outage_without_lease_refuses(gateway):
    gateway.replies(503, {"error": "upstream"})
    with pytest.raises(mac.NotEntitled) as exc:
        mac.transcribe_with_gateway(AUDIO, key=KEY)
    assert exc.value.code == "unreachable"


# --- the route, with STT stubbed and the download prevented -------------------

from fastapi.testclient import TestClient  # noqa: E402


class _FakeResult:
    def __init__(self, text):
        self.text = text


class _FakeModel:
    def __init__(self, text="hello world"):
        self._text = text

    def transcribe(self, path):
        return _FakeResult(self._text)


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
    # Fresh in-memory controller so a persisted cutover cannot leak across tests,
    # and never write warmstart.json to disk during the run.
    monkeypatch.setattr(mac, "_warmstart", mac_warmstart.WarmStartController(enabled=True))
    # The cloud route would otherwise spawn a real HuggingFace download thread.
    monkeypatch.setattr(mac, "_ensure_download_started", lambda: None)
    client = TestClient(mac.app)
    request.addfinalizer(client.close)

    def post(cleanup=True, allow_cloud=False, key=KEY):
        headers = {"X-SunoFlow-Device-Key": f"Bearer {key}"} if key is not None else {}
        return client.post(
            f"/transcribe?cleanup={'true' if cleanup else 'false'}",
            files={"file": ("audio.wav", _wav_bytes(), "audio/wav")},
            data={"context": "", "screen": "", "allow_cloud": "true" if allow_cloud else "false"},
            headers=headers,
        )

    return post


def test_cloud_route_serves_cloud_transcript(route, gateway, monkeypatch):
    monkeypatch.setattr(mac, "model", None)  # local not loaded → cloud route
    gateway.replies(200, {"transcript": "cloud raw", "cleaned": "CLEANED", "lease": gateway.issue_lease(KEY)})
    resp = route(cleanup=True, allow_cloud=True)
    assert resp.status_code == 200, resp.text
    assert resp.json()["raw"] == "cloud raw"
    assert resp.json()["cleaned"] == "CLEANED"
    assert gateway.last_request()["stt_source"] == "cloud"


def test_cloud_route_refuses_a_lapsed_account(route, gateway, monkeypatch):
    monkeypatch.setattr(mac, "model", None)
    gateway.replies(402, {"error": "trial_expired", "message": "Your free trial has ended."})
    resp = route(cleanup=True, allow_cloud=True)
    assert resp.status_code == 402
    assert resp.json() == {"error": "not_entitled", "message": "Your free trial has ended."}


def test_local_route_when_consent_off(route, gateway, monkeypatch):
    monkeypatch.setattr(mac, "model", _FakeModel("local words"))
    gateway.replies(200, {"cleaned": "LOCAL CLEANED", "lease": gateway.issue_lease(KEY)})
    resp = route(cleanup=True, allow_cloud=False)
    assert resp.json()["raw"] == "local words"
    assert resp.json()["cleaned"] == "LOCAL CLEANED"
    assert gateway.last_request()["stt_source"] == "local"
