"""Suno Control proxy parity: sidecar/server.py's copy vs the shared one.

The macOS sidecar carries its own copy of the control proxy, exactly like the
cleanup and answer logic it sits next to. These run the same classification
scenarios against that copy that test_control.py runs against
``sidecars/shared/control.py`` — the drift these catch is the kind that once
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


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(mac, mac_lease, monkeypatch, tmp_path)
    monkeypatch.setattr(
        mac, "CONTROL_URL", f"http://127.0.0.1:{handle._port}/control"
    )
    yield handle
    server.shutdown()
    server.server_close()


def test_refusal_raises_not_entitled_with_code(gateway):
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    with pytest.raises(mac.NotEntitled, match="Your subscription has ended.") as exc:
        mac.plan_action("open calculator", key=KEY)
    assert exc.value.code == "canceled"


def test_no_key_raises_not_connected(gateway):
    with pytest.raises(mac.NotEntitled, match="connected"):
        mac.plan_action("open calculator", key="")


def test_ok_action_passthrough(gateway):
    gateway.replies(200, {"action": "click", "x": 120, "y": 80, "note": "open Calculator"})
    result = mac.plan_action("open calculator", key=KEY)
    assert result["action"] == "click"
    assert result["x"] == 120 and result["y"] == 80


def test_wire_fields(gateway):
    gateway.replies(200, {"action": "done"})
    img = b"\xff\xd8fakejpeg"
    mac.plan_action(
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
    mac.plan_action("x" * 5000, key=KEY)
    assert len(gateway.last_request()["goal"]) == 2000


def test_wire_steps_cap(gateway):
    gateway.replies(200, {"action": "done"})
    steps = [{"action": f"a{i}", "note": "n"} for i in range(120)]
    mac.plan_action("g", steps=steps, key=KEY)
    sent = gateway.last_request()["steps"]
    assert len(sent) == 100
    assert sent[0]["action"] == "a20"
    assert sent[-1]["action"] == "a119"


def test_image_too_large_raises(gateway):
    with pytest.raises(ValueError, match="image too large"):
        mac.plan_action("g", image_bytes=b"x" * (4 << 20), key=KEY)


def test_limit_daily(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=60)
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 60


def test_limit_per_minute(gateway):
    gateway.replies(429, {"error": "limit"}, retry_after=1)
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "limit"
    assert result["retry_after"] == 1


def test_gateway_502_unavailable(gateway):
    gateway.replies(502, {"error": "unavailable"})
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_safety_block_passthrough(gateway):
    """A 502 safety_block keeps its code and message (parity with the shared
    copy) — the app must say 'planner declined this goal', not 'outage'."""
    gateway.replies(502, {"error": "safety_block", "message": "declined this goal"})
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "safety_block"
    assert result["message"] == "declined this goal"


def test_gateway_safety_block_default_message(gateway):
    gateway.replies(502, {"error": "safety_block"})
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "safety_block"
    assert "phrasing" in result["message"]


def test_gateway_safety_block_on_4xx(gateway):
    gateway.replies(503, {"error": "safety_block"})
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "safety_block"


def test_gateway_500_unavailable(gateway):
    gateway.replies(500, {"error": "oops"})
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_non_json_200(gateway):
    gateway.replies(200, b"<html>oops</html>", ctype="text/html")
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_gateway_200_without_action(gateway):
    gateway.replies(200, {"lease": "x"})
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "unavailable"


def test_unreachable_gateway(monkeypatch, gateway):
    monkeypatch.setattr(mac, "CONTROL_URL", "http://127.0.0.1:1/control")
    result = mac.plan_action("g", key=KEY)
    assert result["error"] == "unavailable"