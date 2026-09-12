"""The Suno Try-on proxy — how one generation reaches the gateway.

POST /tryon is a paid feature on the same entitlement as dictation, so its
failure mapping is a paywall question too. The scenarios here run against
``sidecars/shared/tryon.py`` only (the macOS single-file sidecar carries its
own copy of the proxy, exercised for parity in ``sidecar/tests/``).

The proxy's contract: a refusal raises NotEntitled (402 JSON, same shape as
/transcribe); a 429 becomes {"error":"limit", "retry_after": N}; a 502 or any
other gateway failure becomes {"error":"unavailable", ...}; a 200 with an
image returns the gateway's JSON verbatim.
"""
import base64

import pytest

from sidecars.shared import tryon as tryon_mod
from sidecars.shared import lease
from sidecars.shared.tryon import generate_tryon
from sidecars.shared.tests import gateway_stub

KEY = "sf_a_paired_device_key"
PERSON = b"\xff\xd8\xff\xe0personjpeg"
GARMENT = b"\xff\xd8\xff\xe0garmentjpeg"


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(tryon_mod, lease, monkeypatch, tmp_path)
    # gateway_stub.serve patches CLEANUP_URL/ENTITLEMENT_URL on the module it is
    # given; the try-on module's knob is TRYON_URL, so re-point it.
    monkeypatch.setattr(
        tryon_mod, "TRYON_URL",
        f"http://127.0.0.1:{handle._port}/tryon",
    )
    yield handle
    server.shutdown()
    server.server_close()


def test_refusal_raises_not_entitled(gateway):
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    with pytest.raises(tryon_mod.NotEntitled, match="Your subscription has ended."):
        generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)


def test_no_key_raises_not_connected(gateway):
    with pytest.raises(tryon_mod.NotEntitled) as exc:
        generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key="")
    assert getattr(exc.value, "code", "") == "not_connected"


def test_ok_image_passthrough(gateway):
    gateway.replies(200, {"image": "aW1hZ2U=", "mime_type": "image/png", "lease": "a.b"})
    result = generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["image"] == "aW1hZ2U="
    assert result["mime_type"] == "image/png"
    assert result["lease"] == "a.b"


def test_wire_fields(gateway):
    """Item, query, b64 images and bounded context all land on the wire."""
    gateway.replies(200, {"image": "aW1hZ2U="})
    generate_tryon(
        "the green linen shirt", query="try on the green linen shirt",
        person_bytes=PERSON, garment_bytes=GARMENT,
        context={"app": "Safari", "window": "Shop", "junk": "dropped"}, key=KEY,
    )
    body = gateway.last_request()
    assert body["item"] == "the green linen shirt"
    assert body["query"] == "try on the green linen shirt"
    assert body["context"] == {"app": "Safari", "window": "Shop"}
    assert base64.b64decode(body["person"]) == PERSON
    assert base64.b64decode(body["garment"]) == GARMENT


def test_wire_item_cap(gateway):
    gateway.replies(200, {"image": "aW1hZ2U="})
    generate_tryon("x" * 5000, person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert len(gateway.last_request()["item"]) == 500


def test_empty_item_raises(gateway):
    with pytest.raises(ValueError, match="empty item"):
        generate_tryon("   ", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)


def test_missing_person_raises(gateway):
    with pytest.raises(ValueError, match="person"):
        generate_tryon("a shirt", person_bytes=None, garment_bytes=GARMENT, key=KEY)


def test_missing_garment_raises(gateway):
    with pytest.raises(ValueError, match="garment"):
        generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=None, key=KEY)


def test_image_too_large_raises(gateway):
    with pytest.raises(ValueError, match="image too large"):
        generate_tryon("a shirt", person_bytes=b"x" * (4 << 20), garment_bytes=GARMENT, key=KEY)


def test_dictionary_only_when_nonempty(gateway):
    gateway.replies(200, {"image": "aW1hZ2U="})
    generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert "dictionary" not in gateway.last_request()


def test_limit_daily(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=60)
    result = generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 60


def test_limit_per_minute(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=1)
    result = generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 1


def test_gateway_502_unavailable(gateway):
    gateway.replies(502, {"error": "unavailable"})
    result = generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_safety_block_passthrough(gateway):
    """A 502 safety_block keeps its code and message — the app must say
    'model declined this request', not 'outage'."""
    gateway.replies(502, {"error": "safety_block", "message": "declined this request"})
    result = generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "safety_block"
    assert result["message"] == "declined this request"


def test_outage_when_gateway_unreachable(gateway):
    gateway.unreachable()
    result = generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "unavailable"


def test_ok_without_image_is_unavailable(gateway):
    """A 200 without an image body is not a success — the UI must never try to
    render nothing."""
    gateway.replies(200, {"done": True})
    result = generate_tryon("a shirt", person_bytes=PERSON, garment_bytes=GARMENT, key=KEY)
    assert result["error"] == "unavailable"