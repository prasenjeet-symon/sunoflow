"""Route-level try-on tests for the macOS monolith sidecar.

The entitlement-parity suite caught /transcribe raising NameError because a
helper had been renamed without the route catching up — helpers alone are not
enough. These go through FastAPI (TestClient on ``mac.app``), not around it:
/tryon end-to-end against the stub gateway, and the /answer ``tryon`` wire
flag. test_tryon_parity.py covers the proxy function's classification.
"""
import base64
import json

import pytest

from sidecars.shared.tests import gateway_stub

pytest.importorskip("parakeet_mlx", reason="macOS sidecar deps not installed")

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
import lease as mac_lease   # noqa: E402  — sidecar/lease.py, the mirrored copy
import server as mac        # noqa: E402  — sidecar/server.py

from fastapi.testclient import TestClient   # noqa: E402

KEY = "sf_a_paired_device_key"
PERSON = b"\xff\xd8\xff\xe0personjpeg"
GARMENT = b"\xff\xd8\xff\xe0garmentjpeg"


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(mac, mac_lease, monkeypatch, tmp_path)
    monkeypatch.setattr(mac, "TRYON_URL", f"http://127.0.0.1:{handle._port}/tryon")
    monkeypatch.setattr(mac, "ANSWER_URL", f"http://127.0.0.1:{handle._port}/answer")
    yield handle
    server.shutdown()
    server.server_close()


@pytest.fixture
def client(request):
    client = TestClient(mac.app)
    request.addfinalizer(client.close)
    return client


def _tryon_post(client, key=KEY, item="the green linen shirt", person=PERSON, garment=GARMENT, context=None):
    data = {"item": item, "query": "try on " + item}
    if context is not None:
        data["context"] = json.dumps(context)
    files = {}
    if person is not None:
        files["person"] = ("person.jpg", person, "image/jpeg")
    if garment is not None:
        files["garment"] = ("garment.jpg", garment, "image/jpeg")
    headers = {"X-SunoFlow-Device-Key": f"Bearer {key}"} if key is not None else {}
    return client.post("/tryon", data=data, files=files, headers=headers)


def test_the_route_passes_the_image_through(gateway, client):
    gateway.replies(200, {"image": "aW1hZ2U=", "mime_type": "image/png", "lease": "a.b"})
    resp = _tryon_post(client)
    assert resp.status_code == 200
    body = resp.json()
    assert body["image"] == "aW1hZ2U="
    assert body["mime_type"] == "image/png"
    assert body["lease"] == "a.b"


def test_the_route_sends_images_and_context(gateway, client):
    gateway.replies(200, {"image": "aW1hZ2U="})
    resp = _tryon_post(client, context={"app": "Safari", "window": "Shop"})
    assert resp.status_code == 200
    body = gateway.last_request()
    assert body["item"] == "the green linen shirt"
    assert body["context"] == {"app": "Safari", "window": "Shop"}
    assert base64.b64decode(body["person"]) == PERSON
    assert base64.b64decode(body["garment"]) == GARMENT


def test_the_route_refuses_like_transcribe(gateway, client):
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    resp = _tryon_post(client)
    assert resp.status_code == 402
    assert resp.json()["error"] == "canceled"


def test_the_route_needs_a_device_key(gateway, client):
    resp = _tryon_post(client, key="")
    assert resp.status_code == 402
    assert resp.json()["error"] == "not_connected"


def test_the_route_limit_is_200_json(gateway, client):
    gateway.replies(429, {"error": "limit"}, retry_after=60)
    resp = _tryon_post(client)
    assert resp.status_code == 200
    body = resp.json()
    assert body["error"] == "limit"
    assert body["retry_after"] == 60


def test_the_route_empty_item_is_400(gateway, client):
    resp = _tryon_post(client, item="   ")
    assert resp.status_code == 400
    assert resp.json()["error"] == "malformed request"


def test_the_answer_tryon_flag_rides_the_wire(gateway, client):
    gateway.replies(
        200,
        b"event: meta\ndata: {\"lease\": \"abc\"}\n\n"
        b"event: delta\ndata: {\"text\": \"Hi\"}\n\n"
        b"event: done\ndata: {}\n\n",
        ctype="text/event-stream",
    )
    resp = client.post(
        "/answer", data={"query": "try on the green linen shirt", "tryon": "true"},
        headers={"X-SunoFlow-Device-Key": f"Bearer {KEY}"},
    )
    assert resp.status_code == 200
    assert gateway.last_request()["tryon"] is True


def test_the_answer_without_flag_omits_tryon(gateway, client):
    gateway.replies(
        200,
        b"event: meta\ndata: {\"lease\": \"abc\"}\n\n"
        b"event: delta\ndata: {\"text\": \"Hi\"}\n\n"
        b"event: done\ndata: {}\n\n",
        ctype="text/event-stream",
    )
    resp = client.post(
        "/answer", data={"query": "what is rust"},
        headers={"X-SunoFlow-Device-Key": f"Bearer {KEY}"},
    )
    assert resp.status_code == 200
    assert "tryon" not in gateway.last_request()


import base64   # noqa: E402  — used above; kept at the bottom to match file style