"""The /answer route in the shared app skeleton — shape, refusal, pass-through.

The route-level regression net: the entitlement-parity suite caught /transcribe
raising NameError because a helper had been renamed without the route catching
up. These do the same job for /answer — go through FastAPI, not around it.
"""
import json

import pytest

from sidecars.shared import answer as answer_mod
from sidecars.shared import lease
from sidecars.shared.app import SttAdapter, create_app
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
    client = _make_client(tmp_path)
    yield handle, client
    client.close()
    server.shutdown()
    server.server_close()


def _make_client(tmp_path):
    from fastapi.testclient import TestClient
    return TestClient(create_app(FakeAdapter(), str(tmp_path / "corrections.json")))


def _post(client, key=KEY, query="what is rust", history=None, image=None):
    headers = {"X-SunoFlow-Device-Key": f"Bearer {key}"} if key is not None else {}
    data = {"query": query}
    if history is not None:
        data["history"] = json.dumps(history)
    files = {}
    if image is not None:
        files["image"] = ("shot.jpg", image, "image/jpeg")
    return client.post("/answer", data=data, files=files, headers=headers)


def test_the_route_streams_sse(env):
    gateway, client = env
    gateway.replies(200, SSE, ctype="text/event-stream")
    resp = _post(client)
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")
    assert resp.content == SSE  # byte-for-byte passthrough


def test_the_route_refuses_like_transcribe(env):
    gateway, client = env
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    resp = _post(client)
    assert resp.status_code == 402
    body = resp.json()
    assert body["error"] == "canceled"
    assert body["message"] == "Your subscription has ended."


def test_the_route_needs_a_device_key(env):
    gateway, client = env
    resp = _post(client, key="")
    assert resp.status_code == 402
    assert resp.json()["error"] == "not_connected"


def test_the_route_selects_dictionary_entries(env, monkeypatch, tmp_path):
    gateway, client = env
    # Seed a correction so relevant_for has something to select.
    client.post("/corrections/add", data={"frm": "my linkedin", "to": "https://li/x"})
    gateway.replies(200, SSE, ctype="text/event-stream")
    _post(client, query="post my linkedin to the chat")
    req = gateway.last_request()
    assert req["query"] == "post my linkedin to the chat"
    assert req["dictionary"], "relevant dictionary entries must ride the request"


def test_the_route_corrects_the_query_and_announces_it(env):
    gateway, client = env
    # "rust" -> "Rust" is a correction (lookalike re-spelling, auto-applied).
    client.post("/corrections/add", data={"frm": "rust", "to": "Rust"})
    gateway.replies(200, SSE, ctype="text/event-stream")
    resp = _post(client, query="what is rust")
    req = gateway.last_request()
    # The gateway receives the corrected query, not the dictated one.
    assert req["query"] == "what is Rust"
    # The app is told via one extra SSE event ahead of the gateway stream.
    assert resp.content.startswith(b"event: query\ndata: ")
    assert b'"query": "what is Rust"' in resp.content or b'"query":"what is Rust"' in resp.content
    assert resp.content.endswith(SSE)


def test_the_route_keeps_the_query_when_nothing_changed(env):
    gateway, client = env
    gateway.replies(200, SSE, ctype="text/event-stream")
    resp = _post(client, query="what is rust")
    req = gateway.last_request()
    assert req["query"] == "what is rust"
    # Byte-for-byte gateway output when the dictionary had nothing to fix.
    assert resp.content == SSE


def test_the_route_never_substitutes_expansions(env):
    gateway, client = env
    # URL-valued entries are expansions: blind substitution would drop the
    # user's profile URL into any question that merely mentions LinkedIn.
    client.post("/corrections/add", data={"frm": "my linkedin", "to": "https://li/x"})
    gateway.replies(200, SSE, ctype="text/event-stream")
    resp = _post(client, query="what is my linkedin")
    req = gateway.last_request()
    assert req["query"] == "what is my linkedin"
    assert resp.content == SSE


def test_the_route_carries_history_and_image(env):
    gateway, client = env
    gateway.replies(200, SSE, ctype="text/event-stream")
    _post(client, history=[{"q": "first", "a": "first answer"}], image=b"\xff\xd8\xe0")
    req = gateway.last_request()
    assert req["history"] == [{"q": "first", "a": "first answer"}]
    assert req["image"] == "/9jg"


def test_the_route_translates_limit(env):
    gateway, client = env
    gateway.replies(429, {"error": "limit"})
    resp = _post(client)
    assert resp.status_code == 200  # in-stream, not a bare 429
    assert b"event: error" in resp.content
    assert b'"error": "limit"' in resp.content or b'"error":"limit"' in resp.content


def test_the_route_translates_outage(env):
    gateway, client = env
    gateway.replies(503, {"error": "x"})
    resp = _post(client)
    assert resp.status_code == 200
    assert b'"error": "unavailable"' in resp.content or b'"error":"unavailable"' in resp.content