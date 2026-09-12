"""The /answer ``tryon`` flag — how the app turns on try-on directives.

The app only sets this form field when a person photo is on file; the gateway's
answer model then may answer with a [[TRYON]] directive (held back there and
returned as its own ``tryon`` SSE event). From the sidecar's side the flag is
one wire field: set it when asked, leave the request untouched when not, and
pass whatever events come back through byte-for-byte.
"""
import pytest

from sidecars.shared import answer as answer_mod
from sidecars.shared import lease
from sidecars.shared.app import create_app
from sidecars.shared.tests import gateway_stub
from sidecars.shared.tests.test_entitlement import FakeAdapter

KEY = "sf_a_paired_device_key"

SSE = (
    b"event: meta\ndata: {\"lease\": \"abc\"}\n\n"
    b"event: delta\ndata: {\"text\": \"Hi\"}\n\n"
    b"event: done\ndata: {}\n\n"
)


@pytest.fixture
def env(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(answer_mod, lease, monkeypatch, tmp_path)
    monkeypatch.setattr(
        answer_mod, "ANSWER_URL", f"http://127.0.0.1:{handle._port}/answer"
    )
    monkeypatch.setattr("sidecars.shared.cleanup.CLEANUP_KEY", "")
    from fastapi.testclient import TestClient
    client = TestClient(create_app(FakeAdapter(), str(tmp_path / "corrections.json")))
    yield handle, client
    client.close()
    server.shutdown()
    server.server_close()


def test_the_flag_rides_the_wire(env):
    gateway, client = env
    gateway.replies(200, SSE, ctype="text/event-stream")
    resp = client.post(
        "/answer", data={"query": "try on the green linen shirt", "tryon": "true"},
        headers={"X-SunoFlow-Device-Key": f"Bearer {KEY}"},
    )
    assert resp.status_code == 200
    assert gateway.last_request()["tryon"] is True


def test_no_flag_leaves_the_request_alone(env):
    gateway, client = env
    gateway.replies(200, SSE, ctype="text/event-stream")
    resp = client.post(
        "/answer", data={"query": "what is rust"},
        headers={"X-SunoFlow-Device-Key": f"Bearer {KEY}"},
    )
    assert resp.status_code == 200
    assert "tryon" not in gateway.last_request()


def test_events_pass_through_untouched(env):
    """A tryon event in the gateway's stream reaches the app byte-for-byte —
    the proxy does not parse it."""
    gateway, client = env
    stream = (
        b"event: meta\ndata: {\"lease\": \"abc\"}\n\n"
        b"event: tryon\ndata: {\"item\": \"green linen shirt\"}\n\n"
        b"event: done\ndata: {}\n\n"
    )
    gateway.replies(200, stream, ctype="text/event-stream")
    resp = client.post(
        "/answer", data={"query": "try on the green linen shirt", "tryon": "true"},
        headers={"X-SunoFlow-Device-Key": f"Bearer {KEY}"},
    )
    assert resp.status_code == 200
    assert resp.content == stream