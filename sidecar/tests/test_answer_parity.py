"""Suno Answer proxy parity: sidecar/server.py's copy vs the shared one.

The macOS sidecar carries its own copy of the answer proxy, exactly like the
cleanup logic it sits next to. These run the same pre-stream classification
scenarios against that copy that test_answer.py runs against
``sidecars/shared/answer.py`` — the drift these catch is the kind that once
shipped a Windows build with no entitlement checking at all.
"""
import json

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
        mac, "ANSWER_URL", f"http://127.0.0.1:{handle._port}/answer"
    )
    yield handle
    server.shutdown()
    server.server_close()


def _collect(gen):
    return b"".join(gen)


def _events(raw: bytes):
    out = []
    for block in raw.decode().split("\n\n"):
        ev, data = "", ""
        for line in block.split("\n"):
            if line.startswith("event: "):
                ev = line[len("event: "):]
            elif line.startswith("data: "):
                data = line[len("data: "):]
        if ev:
            out.append((ev, data))
    return out


def test_refusal_raises_not_entitled_with_code(gateway):
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    with pytest.raises(mac.NotEntitled, match="Your subscription has ended.") as exc:
        mac.stream_answer("what is rust", key=KEY)
    assert exc.value.code == "canceled"


def test_no_key_raises_not_connected(gateway):
    with pytest.raises(mac.NotEntitled, match="connected"):
        mac.stream_answer("what is rust", key="")


def test_stream_passes_through_byte_for_byte(gateway):
    sse = (
        b"event: meta\ndata: {\"lease\": \"abc\"}\n\n"
        b"event: delta\ndata: {\"text\": \"Hi\"}\n\n"
        b"event: done\ndata: {}\n\n"
    )
    gateway.replies(200, sse, ctype="text/event-stream")
    assert _collect(mac.stream_answer("q", key=KEY)) == sse


def test_daily_limit_maps_to_limit_event(gateway):
    gateway.replies(429, {"error": "rate limit exceeded"}, retry_after=60)
    events = _events(_collect(mac.stream_answer("q", key=KEY)))
    assert json.loads(events[0][1])["error"] == "limit"


def test_per_minute_limit_maps_to_unavailable(gateway):
    gateway.replies(429, {"error": "rate limit exceeded"}, retry_after=1)
    events = _events(_collect(mac.stream_answer("q", key=KEY)))
    assert json.loads(events[0][1])["error"] == "unavailable"


def test_outage_maps_to_unavailable_event(gateway):
    gateway.replies(503, {"error": "x"})
    events = _events(_collect(mac.stream_answer("q", key=KEY)))
    assert json.loads(events[0][1])["error"] == "unavailable"


def test_request_carries_query_history_image_dictionary(gateway):
    gateway.replies(200, b"", ctype="text/event-stream")
    _collect(mac.stream_answer(
        "  what is rust  ",
        history=[{"q": " older ", "a": " answers "}, "not-a-dict"],
        image_bytes=b"\xff\xd8\xe0",
        key=KEY,
        dictionary=[{"from": "my linkedin", "to": "https://x", "kind": "expansion"}],
    ))
    req = gateway.last_request()
    assert req["query"] == "what is rust"
    assert req["history"] == [{"q": "older", "a": "answers"}]  # non-dict turn dropped
    assert req["image"] == "/9jg"
    assert req["dictionary"] == [{"from": "my linkedin", "to": "https://x", "kind": "expansion"}]


def test_oversized_image_rejected_locally(gateway):
    with pytest.raises(ValueError, match="image too large"):
        mac.stream_answer("q", image_bytes=b"x" * (4 << 20), key=KEY)


def test_empty_query_rejected(gateway):
    with pytest.raises(ValueError, match="empty query"):
        mac.stream_answer("   ", key=KEY)