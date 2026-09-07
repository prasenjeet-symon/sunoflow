"""The warm-start routing, through the real /transcribe route.

The controller's own logic is unit-tested in test_warmstart.py; this exercises
the wiring in app.py — that each route actually calls the right transcription
path, that cloud stays authoritative during shadow, that a validated model cuts
over, and that entitlement is still enforced on the cloud path. A live probe of
the installed sidecar once caught /transcribe raising NameError that no
helper-level test noticed, which is why this drives the route.

Run with ``pytest sidecars/shared/tests``.
"""
import io
import struct
import wave

import pytest
from fastapi.testclient import TestClient

from sidecars.shared import cleanup, lease
from sidecars.shared.app import SttAdapter, create_app
from sidecars.shared.tests import gateway_stub

KEY = "sf_a_paired_device_key"


class FakeAdapter(SttAdapter):
    """A model with independently controllable present/loaded state.

    ``present`` (files on disk) is read once at create_app time to decide whether
    this is a fresh install; ``loaded`` (resident in memory) drives routing per
    request. They differ during a warm start: a new install is neither at launch,
    then becomes both once the download finishes.
    """

    def __init__(self, loaded, present=None, local_text="hello world"):
        self._loaded = loaded
        self._present = loaded if present is None else present
        self.local_text = local_text
        self.download_started = 0

    def is_loaded(self):
        return self._loaded

    def is_present(self):
        return self._present

    def load(self):
        pass

    def transcribe_file(self, path):
        return self.local_text

    def status_snapshot(self):
        return {}

    def start_download(self):
        self.download_started += 1
        return {"started": True}


def _wav_bytes(seconds=1.0, rate=16000):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<h", 0) * int(rate * seconds))
    return buf.getvalue()


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(cleanup, lease, monkeypatch, tmp_path)
    yield handle
    server.shutdown()
    server.server_close()


def _client(adapter, tmp_path):
    app = create_app(adapter, str(tmp_path / "corrections.json"))
    return TestClient(app)


def _post(client, cleanup_on=True, allow_cloud=False, key=KEY):
    return client.post(
        f"/transcribe?cleanup={'true' if cleanup_on else 'false'}",
        files={"file": ("audio.wav", _wav_bytes(), "audio/wav")},
        data={"allow_cloud": "true" if allow_cloud else "false"},
        headers={"X-SunoFlow-Device-Key": f"Bearer {key}"},
    )


def test_cloud_route_serves_cloud_and_starts_download(gateway, tmp_path):
    # Not loaded + consent → cloud STT is authoritative, and the local model
    # download is kicked off so the device can eventually cut over.
    adapter = FakeAdapter(loaded=False)
    gateway.replies(200, {"transcript": "cloud raw", "cleaned": "CLEANED", "lease": gateway.issue_lease(KEY)})
    client = _client(adapter, tmp_path)
    try:
        body = _post(client, allow_cloud=True).json()
    finally:
        client.close()
    assert body["raw"] == "cloud raw"
    assert body["cleaned"] == "CLEANED"
    assert adapter.download_started >= 1
    # The cleanup call must tell the gateway this transcript came from the cloud.
    assert gateway.last_request()["stt_source"] == "cloud"


def test_wait_route_returns_empty_without_consent(gateway, tmp_path):
    # Not loaded + no consent → the pre-feature behaviour: a soft empty result.
    client = _client(FakeAdapter(loaded=False), tmp_path)
    try:
        body = _post(client, allow_cloud=False).json()
    finally:
        client.close()
    assert body == {"raw": "", "cleaned": ""}


def test_local_route_when_consent_off(gateway, tmp_path):
    adapter = FakeAdapter(loaded=True, local_text="local words")
    gateway.replies(200, {"cleaned": "LOCAL CLEANED", "lease": gateway.issue_lease(KEY)})
    client = _client(adapter, tmp_path)
    try:
        body = _post(client, allow_cloud=False).json()
    finally:
        client.close()
    assert body["raw"] == "local words"
    assert body["cleaned"] == "LOCAL CLEANED"
    assert gateway.last_request()["stt_source"] == "local"


def test_existing_install_does_not_warm_start(gateway, tmp_path):
    # Model already on disk at launch (an upgrade) → treated as already migrated:
    # even with consent on, the dictation is local and the cloud is never called.
    adapter = FakeAdapter(loaded=True, present=True, local_text="local words")
    gateway.replies(200, {"cleaned": "CLEANED", "lease": gateway.issue_lease(KEY)})
    client = _client(adapter, tmp_path)
    try:
        # Point cloud STT at a dead port: if warm-start wrongly engaged, this
        # would surface as an error instead of a served local dictation.
        cleanup.STT_URL = "http://127.0.0.1:1/stt"
        body = _post(client, allow_cloud=True).json()
        assert body["raw"] == "local words"
        assert client.get("/model/status").json()["warm_start"]["cut_over"] is True
    finally:
        client.close()


def test_shadow_is_authoritative_cloud_then_cuts_over(gateway, tmp_path):
    # A fresh install whose model finishes downloading mid-session: absent at
    # create_app (so it is not seeded as already-migrated), then present+loaded.
    # Loaded + consent → cloud is authoritative while local is validated in the
    # shadow. With local matching cloud (agreement 1.0) and instant inference,
    # three samples cross the cutover gates; afterwards the route is local-only.
    adapter = FakeAdapter(loaded=False, present=False, local_text="hello world")
    gateway.replies(200, {"transcript": "hello world", "cleaned": "SHADOW", "lease": gateway.issue_lease(KEY)})
    client = _client(adapter, tmp_path)
    # The download finishes: the model is now resident.
    adapter._loaded = True
    adapter._present = True
    try:
        first = _post(client, allow_cloud=True).json()
        assert first["raw"] == "hello world"  # cloud, not the unvalidated local
        _post(client, allow_cloud=True)
        _post(client, allow_cloud=True)
        ws = client.get("/model/status").json()["warm_start"]
        assert ws["cut_over"] is True
        assert ws["samples"] >= 3

        # After cutover the cloud is no longer called: even pointed at a dead
        # port, the dictation is served locally.
        cleanup.STT_URL = "http://127.0.0.1:1/stt"
        gateway.replies(200, {"cleaned": "POST", "lease": gateway.issue_lease(KEY)})
        after = _post(client, allow_cloud=True).json()
        assert after["raw"] == "hello world"
        assert after["cleaned"] == "POST"
    finally:
        client.close()


def test_cloud_route_still_enforces_entitlement(gateway, tmp_path):
    gateway.replies(402, {"error": "trial_expired", "message": "Your free trial has ended."})
    client = _client(FakeAdapter(loaded=False), tmp_path)
    try:
        resp = _post(client, allow_cloud=True)
    finally:
        client.close()
    assert resp.status_code == 402
    assert resp.json() == {"error": "not_entitled", "message": "Your free trial has ended."}
