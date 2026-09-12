"""The /control route in the shared app skeleton — shape, refusal, pass-through.

The route-level regression net for Suno Control, mirroring
``test_answer_route.py``: go through FastAPI, not around it. The contract: a
refusal is the same 402 /transcribe returns; a 200 passes the gateway's action
JSON through verbatim; limit/outage come back as 200 {"error": ...} so the
app's loop stops on one shape.
"""
import base64
import json

import pytest

from sidecars.shared import control as control_mod
from sidecars.shared import lease
from sidecars.shared.app import create_app
from sidecars.shared.tests import gateway_stub
from sidecars.shared.tests.test_entitlement import FakeAdapter

KEY = "sf_a_paired_device_key"


@pytest.fixture
def env(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(control_mod, lease, monkeypatch, tmp_path)
    monkeypatch.setattr(
        control_mod, "CONTROL_URL", f"http://127.0.0.1:{handle._port}/control"
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


def _post(client, key=KEY, goal="open calculator", steps=None, image=None, context=None):
    headers = {"X-SunoFlow-Device-Key": f"Bearer {key}"} if key is not None else {}
    data = {"goal": goal}
    if steps is not None:
        data["steps"] = json.dumps(steps)
    if context is not None:
        data["context"] = json.dumps(context)
    files = {}
    if image is not None:
        files["image"] = ("shot.jpg", image, "image/jpeg")
    return client.post("/control", data=data, files=files, headers=headers)


def test_the_route_passes_the_action_through(env):
    gateway, client = env
    gateway.replies(200, {"action": "click", "x": 12, "y": 34, "note": "n", "lease": "a.b"})
    resp = _post(client, context={"app": "Finder"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["action"] == "click"
    assert body["x"] == 12 and body["y"] == 34
    assert body["lease"] == "a.b"


def test_the_route_sends_steps_image_context(env):
    gateway, client = env
    gateway.replies(200, {"action": "done"})
    img = b"\xff\xd8fake"
    resp = _post(client, steps=[{"action": "click", "note": "dock"}], image=img,
                 context={"app": "Finder", "cursor_x": 5, "cursor_y": 6})
    assert resp.status_code == 200
    body = gateway.last_request()
    assert body["steps"] == [{"action": "click", "note": "dock"}]
    assert base64.b64decode(body["image"]) == img
    assert body["context"] == {"app": "Finder", "cursor_x": 5, "cursor_y": 6}


def test_the_route_applies_corrections_to_the_goal(env, tmp_path):
    """A correction file that rewrites the goal is applied before the gateway
    sees it — a mis-heard goal drives a mis-heard plan."""
    gateway, client = env
    corr = tmp_path / "corrections.json"
    corr.write_text(json.dumps({"calcylator": {"from": "calcylator", "to": "Calculator"}}), encoding="utf-8")
    client.close()
    from fastapi.testclient import TestClient
    client = TestClient(create_app(FakeAdapter(), str(corr)))

    gateway.replies(200, {"action": "done"})
    resp = _post(client, goal="open calcylator")
    assert resp.status_code == 200
    assert gateway.last_request()["goal"] == "open Calculator"


def test_the_route_sends_relevant_dictionary(env, tmp_path):
    gateway, client = env
    corr = tmp_path / "corrections.json"
    corr.write_text(json.dumps({
        "linkdin": {"from": "Linkdin", "to": "https://linkedin.com/in/me", "kind": "expansion"},
    }), encoding="utf-8")
    client.close()
    from fastapi.testclient import TestClient
    client = TestClient(create_app(FakeAdapter(), str(corr)))

    gateway.replies(200, {"action": "done"})
    resp = _post(client, goal="go to linkdin")
    assert resp.status_code == 200
    d = gateway.last_request().get("dictionary")
    assert d and any(e.get("to") == "https://linkedin.com/in/me" for e in d)


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


def test_the_route_limit_is_200_json(env):
    gateway, client = env
    gateway.replies(429, {"error": "limit"}, retry_after=60)
    resp = _post(client)
    assert resp.status_code == 200
    body = resp.json()
    assert body["error"] == "limit"
    assert body["retry_after"] == 60


def test_the_route_outage_is_200_json(env):
    gateway, client = env
    gateway.replies(502, {"error": "unavailable"})
    resp = _post(client)
    assert resp.status_code == 200
    assert resp.json()["error"] == "unavailable"


def test_the_route_empty_goal_is_400(env):
    gateway, client = env
    resp = _post(client, goal="   ")
    assert resp.status_code == 400
    assert resp.json()["error"] == "malformed request"


def test_the_route_bad_steps_json_is_tolerated(env):
    """A garbage steps/context payload degrades to empty, not an error — the
    loop keeps working with lost history rather than dying on it."""
    gateway, client = env
    gateway.replies(200, {"action": "done"})
    headers = {"X-SunoFlow-Device-Key": f"Bearer {KEY}"}
    resp = client.post("/control", data={"goal": "g", "steps": "not json", "context": "["},
                       headers=headers)
    assert resp.status_code == 200
    body = gateway.last_request()
    assert body["steps"] == []
    assert body["context"] == {}