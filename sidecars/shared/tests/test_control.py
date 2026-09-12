"""The Suno Control proxy — how one planning step reaches the gateway.

POST /control is a paid feature on the same entitlement as dictation, so its
failure mapping is a paywall question too. The scenarios here run against
``sidecars/shared/control.py`` only (the macOS single-file sidecar carries its
own copy of the proxy, exercised for parity in ``sidecar/tests/``).

The proxy's contract: a refusal raises NotEntitled (402 JSON, same shape as
/transcribe); a 429 becomes {"error":"limit", "retry_after": N}; a 502 or any
other gateway failure becomes {"error":"unavailable", ...}; a 200 returns the
gateway's action JSON verbatim.
"""
import base64
import json

import pytest

from sidecars.shared import control as control_mod
from sidecars.shared import lease
from sidecars.shared.control import plan_action
from sidecars.shared.tests import gateway_stub

KEY = "sf_a_paired_device_key"


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(control_mod, lease, monkeypatch, tmp_path)
    # gateway_stub.serve patches CLEANUP_URL/ENTITLEMENT_URL on the module it is
    # given; the control module's knob is CONTROL_URL, so re-point it.
    monkeypatch.setattr(
        control_mod, "CONTROL_URL",
        f"http://127.0.0.1:{handle._port}/control",
    )
    yield handle
    server.shutdown()
    server.server_close()


def test_refusal_raises_not_entitled(gateway):
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    with pytest.raises(control_mod.NotEntitled, match="Your subscription has ended."):
        plan_action("open calculator", key=KEY)


def test_no_key_raises_not_connected(gateway):
    with pytest.raises(control_mod.NotEntitled) as exc:
        plan_action("open calculator", key="")
    assert getattr(exc.value, "code", "") == "not_connected"


def test_ok_action_passthrough(gateway):
    gateway.replies(200, {
        "action": "click", "x": 120, "y": 80, "note": "open Calculator",
        "lease": "a.b",
    })
    result = plan_action("open calculator", key=KEY)
    assert result["action"] == "click"
    assert result["x"] == 120 and result["y"] == 80
    assert result["lease"] == "a.b"


def test_wire_fields(gateway):
    """Goal, bounded steps, b64 image and context all land on the wire."""
    gateway.replies(200, {"action": "type", "text": "hello"})
    img = b"\xff\xd8\xff\xe0fakejpeg"
    plan_action(
        "open calculator", steps=[{"action": "click", "note": "dock"}],
        image_bytes=img, context={"app": "Finder"}, key=KEY,
    )
    body = gateway.last_request()
    assert body["goal"] == "open calculator"
    assert body["steps"] == [{"action": "click", "note": "dock"}]
    assert body["context"] == {"app": "Finder"}
    assert base64.b64decode(body["image"]) == img


def test_wire_goal_cap(gateway):
    gateway.replies(200, {"action": "done"})
    plan_action("x" * 5000, key=KEY)
    assert len(gateway.last_request()["goal"]) == 2000


def test_wire_steps_cap_and_drop(gateway):
    """Over-cap steps are truncated to the last 100; junk entries dropped."""
    gateway.replies(200, {"action": "done"})
    steps = [{"action": f"a{i}", "note": "n"} for i in range(120)]
    steps += ["junk", 42, {"note": "no action"}, {"action": "  "}]
    plan_action("g", steps=steps, key=KEY)
    sent = gateway.last_request()["steps"]
    assert len(sent) == 100
    assert sent[0]["action"] == "a20"
    assert sent[-1]["action"] == "a119"


def test_wire_step_note_cap(gateway):
    gateway.replies(200, {"action": "done"})
    plan_action("g", steps=[{"action": "click", "note": "n" * 500}], key=KEY)
    sent = gateway.last_request()["steps"]
    assert len(sent[0]["note"]) == 300


def test_image_too_large_raises(gateway):
    with pytest.raises(ValueError, match="image too large"):
        plan_action("g", image_bytes=b"x" * (4 << 20), key=KEY)


def test_empty_goal_raises(gateway):
    with pytest.raises(ValueError, match="empty goal"):
        plan_action("   ", key=KEY)


def test_limit_daily(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=60)
    result = plan_action("g", key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 60


def test_limit_per_minute(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=1)
    result = plan_action("g", key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 1


def test_gateway_502_unavailable(gateway):
    gateway.replies(502, {"error": "unavailable"})
    result = plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_safety_block_passthrough(gateway):
    """A 502 safety_block keeps its code and message — the app must be able to
    say 'the planner declined this goal' instead of 'unavailable right now'."""
    gateway.replies(502, {"error": "safety_block", "message": "declined this goal"})
    result = plan_action("g", key=KEY)
    assert result["error"] == "safety_block"
    assert result["message"] == "declined this goal"


def test_gateway_safety_block_default_message(gateway):
    """A safety_block body without a message gets the rephrase guidance."""
    gateway.replies(502, {"error": "safety_block"})
    result = plan_action("g", key=KEY)
    assert result["error"] == "safety_block"
    assert "phrasing" in result["message"]


def test_gateway_safety_block_on_4xx(gateway):
    """The safety pass-through keys on the body's error code, not the status —
    a safety_block arriving on any non-2xx still passes through."""
    gateway.replies(503, {"error": "safety_block"})
    result = plan_action("g", key=KEY)
    assert result["error"] == "safety_block"


def test_gateway_500_unavailable(gateway):
    gateway.replies(500, {"error": "oops"})
    result = plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_non_json_200(gateway):
    gateway.replies(200, b"<html>oops</html>", ctype="text/html")
    result = plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_200_without_action(gateway):
    gateway.replies(200, {"lease": "x"})  # no "action" field
    result = plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_unreachable_gateway(monkeypatch, gateway):
    monkeypatch.setattr(control_mod, "CONTROL_URL", "http://127.0.0.1:1/control")
    result = plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_image_not_b64_decodable_by_gateway_still_ok(gateway):
    """The sidecar b64-encodes whatever bytes it got; decoding is the gateway's
    problem. The wire payload must always be valid base64 of the bytes."""
    gateway.replies(200, {"action": "wait", "seconds": 1.5, "seconds2": None})
    result = plan_action("g", image_bytes=b"\x00\x01\x02", key=KEY)
    assert result["action"] == "wait"