"""The /tryon route — how one generation reaches the gateway.

POST /tryon is a paid feature on the same entitlement as dictation, so its
failure mapping is a paywall question too. These run the full FastAPI route
against the gateway stub; the proxy function's own classification scenarios
run in test_tryon.py, and the macOS single-file sidecar carries its own copy
of everything, exercised for parity in sidecar/tests/.
"""
import base64
import json

import pytest
from fastapi.testclient import TestClient

from sidecars.shared.app import create_app
from sidecars.shared import tryon as tryon_mod
from sidecars.shared.tests.test_entitlement import FakeAdapter
from sidecars.shared.tests import gateway_stub

KEY = "sf_a_paired_device_key"

PERSON = b"\xff\xd8\xff\xe0personjpeg"
GARMENT = b"\xff\xd8\xff\xe0garmentjpeg"


@pytest.fixture
def env(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(tryon_mod, __import__(
        "sidecars.shared.lease", fromlist=["lease"]
    ), monkeypatch, tmp_path)
    # gateway_stub.serve patches CLEANUP_URL/ENTITLEMENT_URL on the module it is
    # given; the try-on module's knob is TRYON_URL, so re-point it.
    monkeypatch.setattr(
        tryon_mod, "TRYON_URL", f"http://127.0.0.1:{handle._port}/tryon"
    )
    monkeypatch.setattr("sidecars.shared.cleanup.CLEANUP_KEY", "")
    client = TestClient(create_app(FakeAdapter(), str(tmp_path / "corrections.json")))
    yield handle, client
    client.close()
    server.shutdown()
    server.server_close()


def _post(client, key=KEY, item="the green linen shirt", query="try on the green linen shirt",
          person=PERSON, garment=GARMENT, context=None):
    data = {"item": item, "query": query}
    if context is not None:
        data["context"] = json.dumps(context)
    files = {}
    if person is not None:
        files["person"] = ("person.jpg", person, "image/jpeg")
    if garment is not None:
        files["garment"] = ("garment.jpg", garment, "image/jpeg")
    return client.post(
        "/tryon", data=data, files=files,
        headers={"X-SunoFlow-Device-Key": key},
    )


def test_the_route_passes_the_image_through(env):
    gateway, client = env
    gateway.replies(200, {"image": "aW1hZ2U=", "mime_type": "image/png", "lease": "a.b"})
    resp = _post(client)
    assert resp.status_code == 200
    body = resp.json()
    assert body["image"] == "aW1hZ2U="
    assert body["mime_type"] == "image/png"
    assert body["lease"] == "a.b"


def test_the_route_sends_item_query_images_context(env):
    gateway, client = env
    gateway.replies(200, {"image": "aW1hZ2U="})
    resp = _post(client, context={"app": "Safari", "window": "Shop"})
    assert resp.status_code == 200
    body = gateway.last_request()
    assert body["item"] == "the green linen shirt"
    assert body["query"] == "try on the green linen shirt"
    assert body["context"] == {"app": "Safari", "window": "Shop"}
    assert base64.b64decode(body["person"]) == PERSON
    assert base64.b64decode(body["garment"]) == GARMENT


def test_the_route_applies_corrections_to_the_item(env, tmp_path):
    """A correction file that rewrites the item is applied before the gateway
    sees it — a mis-heard item renders a garment the user never said."""
    gateway, client = env
    corr = tmp_path / "corrections.json"
    corr.write_text(json.dumps({"linnin": {"from": "linnin", "to": "linen", "count": 3}}), encoding="utf-8")
    client.close()
    from fastapi.testclient import TestClient
    client = TestClient(create_app(FakeAdapter(), str(corr)))

    gateway.replies(200, {"image": "aW1hZ2U="})
    resp = _post(client, item="the green linnin shirt")
    assert resp.status_code == 200
    # The gateway sees the corrected item.
    assert gateway.last_request()["item"] == "the green linen shirt"


def test_the_route_sends_relevant_dictionary(env, tmp_path):
    gateway, client = env
    corr = tmp_path / "corrections.json"
    corr.write_text(json.dumps({
        "linnin": {"from": "linnin", "to": "linen", "count": 3},
        "kuberntes": {"from": "kuberntes", "to": "Kubernetes", "count": 2},
    }), encoding="utf-8")
    client.close()
    from fastapi.testclient import TestClient
    client = TestClient(create_app(FakeAdapter(), str(corr)))

    gateway.replies(200, {"image": "aW1hZ2U="})
    resp = _post(client, item="a linnin shirt")
    assert resp.status_code == 200
    sent = gateway.last_request().get("dictionary") or []
    froms = [entry["from"] for entry in sent]
    assert "linnin" in froms
    assert "kuberntes" not in froms


def test_the_route_refuses_like_transcribe(env):
    gateway, client = env
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    resp = _post(client)
    assert resp.status_code == 402
    assert resp.json() == {"error": "canceled", "message": "Your subscription has ended."}


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


def test_the_route_safety_block_passes_through(env):
    gateway, client = env
    gateway.replies(502, {"error": "safety_block", "message": "declined this request"})
    resp = _post(client)
    assert resp.status_code == 200
    body = resp.json()
    assert body["error"] == "safety_block"
    assert body["message"] == "declined this request"


def test_the_route_empty_item_is_400(env):
    gateway, client = env
    resp = _post(client, item="   ")
    assert resp.status_code == 400
    assert resp.json()["error"] == "malformed request"


def test_the_route_garbage_context_is_tolerated(env):
    gateway, client = env
    gateway.replies(200, {"image": "aW1hZ2U="})
    resp = client.post(
        "/tryon",
        data={"item": "a shirt", "query": "", "context": "{not json"},
        files={
            "person": ("person.jpg", PERSON, "image/jpeg"),
            "garment": ("garment.jpg", GARMENT, "image/jpeg"),
        },
        headers={"X-SunoFlow-Device-Key": KEY},
    )
    assert resp.status_code == 200
    assert gateway.last_request()["context"] == {"app": "", "window": ""}