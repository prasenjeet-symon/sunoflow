"""The Suno Answer SSE proxy — how failures before the stream are classified.

POST /answer is a paid feature on the same entitlement as dictation, so its
failure mapping is a paywall question too. The scenarios here run against
``sidecars/shared/answer.py`` only (the macOS single-file sidecar carries its
own copy of the proxy, exercised for parity in ``sidecar/tests/``).

The proxy's contract: a refusal raises NotEntitled (402 JSON, same shape as
/transcribe); a 429 becomes an in-stream ``limit`` event; any other pre-stream
failure becomes an in-stream ``unavailable`` event; a 200 pipes the gateway's
SSE bytes through untouched.
"""
import json

import pytest

from sidecars.shared import answer as answer_mod
from sidecars.shared import lease
from sidecars.shared.answer import stream_answer
from sidecars.shared.tests import gateway_stub

KEY = "sf_a_paired_device_key"


@pytest.fixture
def gateway(monkeypatch, tmp_path):
    server, handle = gateway_stub.serve(answer_mod, lease, monkeypatch, tmp_path)
    # gateway_stub.serve patches CLEANUP_URL/ENTITLEMENT_URL on the module it
    # is given; the answer module's knob is ANSWER_URL, so re-point it.
    monkeypatch.setattr(
        answer_mod, "ANSWER_URL",
        f"http://127.0.0.1:{handle._port}/answer",
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


def test_refusal_raises_not_entitled(gateway):
    gateway.replies(402, {"error": "canceled", "message": "Your subscription has ended."})
    with pytest.raises(answer_mod.NotEntitled, match="Your subscription has ended."):
        stream_answer("what is rust", key=KEY)


def test_no_key_raises_not_connected(gateway):
    with pytest.raises(answer_mod.NotEntitled, match="connected"):
        stream_answer("what is rust", key="")


def test_limit_maps_to_error_event(gateway):
    gateway.replies(429, {"error": "limit"})
    raw = _collect(stream_answer("q", key=KEY))
    events = _events(raw)
    assert len(events) == 1
    assert events[0][0] == "error"
    assert json.loads(events[0][1])["error"] == "limit"


def test_outage_maps_to_unavailable_event(gateway):
    gateway.replies(503, {"error": "x"})
    events = _events(_collect(stream_answer("q", key=KEY)))
    assert events[0][0] == "error"
    assert json.loads(events[0][1])["error"] == "unavailable"


def test_stream_passes_through(gateway):
    sse = (
        b"event: meta\ndata: {\"lease\": \"abc\"}\n\n"
        b"event: delta\ndata: {\"text\": \"Hel\"}\n\n"
        b"event: delta\ndata: {\"text\": \"lo\"}\n\n"
        b"event: sources\ndata: {\"domains\": [\"example.com\"], \"queries\": 1}\n\n"
        b"event: done\ndata: {}\n\n"
    )
    gateway.replies(200, sse, ctype="text/event-stream")
    raw = _collect(stream_answer("q", key=KEY))
    assert raw == sse  # byte-for-byte passthrough


def test_request_carries_query_history_and_image(gateway):
    gateway.replies(200, b"", ctype="text/event-stream")
    _collect(stream_answer(
        "  what is rust  ",
        history=[{"q": " older ", "a": " answers "}, {"q": "", "a": ""}],
        image_bytes=b"\xff\xd8\xe0",
        key=KEY,
        dictionary=[{"from": "my linkedin", "to": "https://x", "kind": "expansion"}],
    ))
    req = gateway.last_request()
    assert req["query"] == "what is rust"
    assert req["history"] == [{"q": "older", "a": "answers"}]  # empty turn dropped
    assert req["image"] == "/9jg"  # base64 of the 3 magic bytes
    assert req["dictionary"] == [{"from": "my linkedin", "to": "https://x", "kind": "expansion"}]


def test_image_omitted_when_absent(gateway):
    gateway.replies(200, b"", ctype="text/event-stream")
    _collect(stream_answer("q", key=KEY))
    assert "image" not in gateway.last_request()


def test_oversized_image_rejected_locally(gateway):
    with pytest.raises(ValueError, match="image too large"):
        stream_answer("q", image_bytes=b"x" * (4 << 20), key=KEY)


def test_empty_query_rejected(gateway):
    with pytest.raises(ValueError, match="empty query"):
        stream_answer("   ", key=KEY)


def test_network_failure_becomes_unavailable(gateway, monkeypatch):
    monkeypatch.setattr(answer_mod, "ANSWER_URL", "http://127.0.0.1:1/answer")
    events = _events(_collect(stream_answer("q", key=KEY)))
    assert events[0][0] == "error"
    assert json.loads(events[0][1])["error"] == "unavailable"

def test_per_minute_limit_is_not_told_as_daily(gateway):
    """Retry-After: 1 is the per-minute bucket — a slow-down, not a day over."""
    gateway.replies(429, {"error": "rate limit exceeded"}, retry_after=1)
    events = _events(_collect(stream_answer("q", key=KEY)))
    assert json.loads(events[0][1])["error"] == "unavailable"
    assert "seconds" in json.loads(events[0][1])["message"]

    gateway.replies(429, {"error": "rate limit exceeded"}, retry_after=60)
    events = _events(_collect(stream_answer("q", key=KEY)))
    assert json.loads(events[0][1])["error"] == "limit"
