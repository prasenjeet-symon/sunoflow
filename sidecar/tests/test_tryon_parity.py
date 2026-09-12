"""Suno Try-on proxy parity: sidecar/server.py's copy vs the shared one.

The macOS sidecar carries its own copy of the try-on proxy, exactly like the
cleanup, answer, and control logic it sits next to. These run the same
classification scenarios against that copy that test_tryon.py runs against
``sidecars/shared/tryon.py`` — the drift these catch is the kind that once
shipped a Windows build with no entitlement checking at all.
"""
import base64

import pytest

from sidecars.shared.tests import gateway_stub

pytest.importorskip("parakeet_mlx", reason="macOS sidecar deps not installed")

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
import lease as mac_lease   # noqa: E402  — sidecar/lease.py, the mirrored copy
import server as mac        # noqa: E402  — sidecar/server.py

KEY = "sf_a_paired_device_key"
PERSON = b"\xff\xd8\xff\xe0personjpeg"
GARMENT = b"\xff\xd8\xff\xe0garmentjpeg"


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(mac, mac_lease, monkeypatch, tmp_path)
    monkeypatch.setattr(
        mac, "TRYON_URL", f"http://127.0.0.1:{handle._port}/tryon"
    )
    yield handle
    server.shutdown()
    server.server_close()


def test_refusal_raises_not_entitled_with_code(gateway):
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    with pytest.raises(mac.NotEntitled, match="Your subscription has ended.") as exc:
        mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert exc.value.code == "canceled"


def test_no_key_raises_not_connected(gateway):
    with pytest.raises(mac.NotEntitled, match="connected"):
        mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key="")


def test_ok_image_passthrough(gateway):
    gateway.replies(200, {"image": "aW1hZ2U=", "mime_type": "image/png"})
    result = mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["image"] == "aW1hZ2U="
    assert result["mime_type"] == "image/png"


def test_wire_fields(gateway):
    gateway.replies(200, {"image": "aW1hZ2U="})
    mac.generate_tryon(
        "the green linen shirt", query="try on the green linen shirt",
        person_bytes=PERSON, garment_bytes=GARMENT,
        context={"app": "Safari", "window": "Shop"}, key=KEY,
    )
    body = gateway.last_request()
    assert body["item"] == "the green linen shirt"
    assert body["query"] == "try on the green linen shirt"
    assert body["context"] == {"app": "Safari", "window": "Shop"}
    assert base64.b64decode(body["person"]) == PERSON
    assert base64.b64decode(body["garment"]) == GARMENT


def test_wire_item_cap(gateway):
    gateway.replies(200, {"image": "aW1hZ2U="})
    mac.generate_tryon("x" * 5000, person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert len(gateway.last_request()["item"]) == 500


def test_empty_item_raises(gateway):
    with pytest.raises(ValueError, match="empty item"):
        mac.generate_tryon("   ", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)


def test_missing_person_raises(gateway):
    with pytest.raises(ValueError, match="person"):
        mac.generate_tryon("a shirt", person_bytes=None, garment_bytes=GARMENT, key=KEY)


def test_missing_garment_raises(gateway):
    with pytest.raises(ValueError, match="garment"):
        mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=None, key=KEY)


def test_image_too_large_raises(gateway):
    with pytest.raises(ValueError, match="image too large"):
        mac.generate_tryon("a shirt", person_bytes=b"x" * (4 << 20), garment_bytes=GARMENT, key=KEY)


def test_limit_daily(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=60)
    result = mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 60


def test_limit_per_minute(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=1)
    result = mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 1


def test_gateway_502_unavailable(gateway):
    gateway.replies(502, {"error": "unavailable"})
    result = mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_safety_block_passthrough(gateway):
    """A 502 safety_block keeps its code and message (parity with the shared
    copy) — the app must say 'model declined this request', not 'outage'."""
    gateway.replies(502, {"error": "safety_block", "message": "declined this request"})
    result = mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "safety_block"
    assert result["message"] == "declined this request"


def test_outage_when_gateway_unreachable(gateway):
    gateway.unreachable()
    result = mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "unavailable"


def test_ok_without_image_is_unavailable(gateway):
    """A 200 without an image body is not a success — the UI must never try to
    render nothing."""
    gateway.replies(200, {"done": True})
    result = mac.generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "unavailable"