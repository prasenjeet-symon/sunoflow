"""Every dictation must be checked against the account, on every platform.

These are the tests the Windows sidecar did not have. It shipped serving every
dictation for free: /transcribe accepted no device key, never called the
entitlement probe when cleanup was off, and had no handler turning a refusal
into a 402 the app could act on. Each of those is pinned here.
"""
import io
import struct
import wave

import pytest
from fastapi.testclient import TestClient

from sidecars.shared import app as app_module
from sidecars.shared.app import SttAdapter, create_app
from sidecars.shared.cleanup import NotEntitled

KEY = "sf_a_paired_device_key"


def _wav_bytes(seconds: float = 1.0, rate: int = 16000) -> bytes:
    """A silent clip long enough to clear the too-short guard."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<h", 0) * int(rate * seconds))
    return buf.getvalue()


class FakeAdapter(SttAdapter):
    def is_loaded(self):
        return True

    def is_present(self):
        return True

    def load(self):
        pass

    def transcribe_file(self, path):
        return "hello world"

    def status_snapshot(self):
        return {}

    def start_download(self):
        return {"started": False}


@pytest.fixture
def client(tmp_path, monkeypatch):
    # A dev machine may have SUNOFLOW_CLEANUP_KEY set, which would stand in for
    # a missing device key and send the "unconnected" cases at the real gateway.
    monkeypatch.setattr("sidecars.shared.cleanup.CLEANUP_KEY", "")
    return TestClient(create_app(FakeAdapter(), str(tmp_path / "corrections.json")))


def _post(client, *, cleanup=True, key=KEY, tone=None):
    headers = {"X-SunoFlow-Device-Key": f"Bearer {key}"} if key is not None else {}
    data = {"context": "", "screen": ""}
    if tone is not None:
        data["tone"] = tone
    return client.post(
        f"/transcribe?cleanup={'true' if cleanup else 'false'}",
        files={"file": ("audio.wav", _wav_bytes(), "audio/wav")},
        data=data,
        headers=headers,
    )


# --- the device key must actually reach the gateway call ----------------------

def test_the_device_key_is_forwarded_to_the_cleanup_call(client, monkeypatch):
    seen = {}

    def fake_clean(text, context="", recent=None, screen="", key="",
                   dictionary=None, tone="", app="", app_site="", app_detail=""):
        seen["key"] = key
        return "Hello world."

    monkeypatch.setattr(app_module, "clean_with_gateway", fake_clean)
    resp = _post(client)

    assert resp.status_code == 200
    assert seen["key"] == KEY, "the sidecar dropped the device key: every dictation would be unauthenticated"


def test_the_bearer_prefix_is_stripped(client, monkeypatch):
    seen = {}
    monkeypatch.setattr(app_module, "clean_with_gateway",
                        lambda text, context="", recent=None, screen="", key="",
                        dictionary=None, tone="", app="", app_site="",
                        app_detail="": seen.setdefault("key", key) or "x")
    _post(client)
    assert not seen["key"].startswith("Bearer")


# --- a refusal must stop the dictation ----------------------------------------

def test_a_refused_dictation_returns_402_and_no_text(client, monkeypatch):
    def refuse(*a, **kw):
        raise NotEntitled("Your free trial has ended.")

    monkeypatch.setattr(app_module, "clean_with_gateway", refuse)
    resp = _post(client)

    assert resp.status_code == 402
    body = resp.json()
    assert body["error"] == "not_entitled"
    assert body["message"] == "Your free trial has ended."
    assert "cleaned" not in body, "a refused dictation must not hand back any text"


def test_a_refusal_is_not_swallowed_into_a_200(client, monkeypatch):
    """The original bug: NotEntitled escaped as an unhandled 500, or worse, the
    raw transcript came back with a 200 and got pasted."""
    monkeypatch.setattr(app_module, "clean_with_gateway",
                        lambda *a, **kw: (_ for _ in ()).throw(NotEntitled("nope")))
    resp = _post(client)
    assert resp.status_code == 402
    assert resp.status_code != 500


# --- turning cleanup off must not be a free-dictation switch ------------------

def test_cleanup_off_still_checks_entitlement(client, monkeypatch):
    called = {}
    monkeypatch.setattr(app_module, "check_entitlement", lambda key: called.setdefault("key", key))
    monkeypatch.setattr(app_module, "clean_with_gateway",
                        lambda *a, **kw: pytest.fail("cleanup must not run when it is switched off"))

    resp = _post(client, cleanup=False)

    assert resp.status_code == 200
    assert called["key"] == KEY, "switching cleanup off skipped the only entitlement check"


def test_cleanup_off_is_refused_when_the_account_has_lapsed(client, monkeypatch):
    def refuse(key):
        raise NotEntitled("Your subscription has ended.")

    monkeypatch.setattr(app_module, "check_entitlement", refuse)
    resp = _post(client, cleanup=False)

    assert resp.status_code == 402
    assert resp.json()["message"] == "Your subscription has ended."


# --- an unconnected install ---------------------------------------------------

def test_no_device_key_is_refused(client):
    """No header at all: the real check_entitlement/clean_with_gateway refuse an
    empty key, so an unpaired caller — including one curling the port directly —
    gets a 402 rather than free dictation."""
    resp = _post(client, cleanup=False, key=None)
    assert resp.status_code == 402


def test_no_device_key_is_refused_with_cleanup_on(client):
    resp = _post(client, cleanup=True, key=None)
    assert resp.status_code == 402


# --- an outage and a lapse must not read the same -----------------------------

def test_a_refusal_and_an_outage_carry_different_codes(client, monkeypatch):
    """Both stop the dictation, but the user fixes them in different places, so
    the app has to be able to tell them apart without parsing prose."""
    monkeypatch.setattr(app_module, "clean_with_gateway",
                        lambda *a, **kw: (_ for _ in ()).throw(NotEntitled("lapsed")))
    assert client and _post(client).json()["error"] == "not_entitled"

    monkeypatch.setattr(app_module, "clean_with_gateway",
                        lambda *a, **kw: (_ for _ in ()).throw(
                            NotEntitled("can't reach us", code="unreachable")))
    body = _post(client).json()
    assert body["error"] == "unreachable"
    assert body["message"] == "can't reach us"


def test_an_unconnected_device_says_so(client):
    assert _post(client, key=None).json()["error"] == "not_connected"


# --- the chosen tone reaches the gateway call ---------------------------------

def _capture_tone(monkeypatch):
    """Stand in for the gateway call and record the tone it was handed."""
    seen = {}

    def fake(text, context="", recent=None, screen="", key="", dictionary=None,
             tone="", app="", app_site="", app_detail=""):
        seen["tone"] = tone
        return text

    monkeypatch.setattr(app_module, "clean_with_gateway", fake)
    return seen


def test_the_tone_form_field_reaches_the_gateway_call(client, monkeypatch):
    """The field is easy to add to the endpoint and forget to forward, and the
    failure is silent: every dictation would come back in the default voice with
    nothing in the logs to say why."""
    seen = _capture_tone(monkeypatch)
    assert _post(client, tone="formal").status_code == 200
    assert seen["tone"] == "formal"


def test_no_tone_field_means_the_default_voice(client, monkeypatch):
    """Covers the apps shipped before tones existed, which post no such field."""
    seen = _capture_tone(monkeypatch)
    assert _post(client).status_code == 200
    assert seen["tone"] == ""


# --- where the user is dictating reaches the gateway call ---------------------

def test_the_app_form_fields_reach_the_gateway_call(client, monkeypatch):
    """Exactly the failure the tone test guards against, one field family over:
    the endpoint accepts them, forgets to forward them, and every dictation is
    cleaned without knowing where it is going — with nothing in the logs."""
    seen = {}

    def fake(text, context="", recent=None, screen="", key="", dictionary=None,
             tone="", app="", app_site="", app_detail=""):
        seen.update(app=app, app_site=app_site, app_detail=app_detail)
        return text

    monkeypatch.setattr(app_module, "clean_with_gateway", fake)
    resp = client.post(
        "/transcribe",
        files={"file": ("audio.wav", _wav_bytes(), "audio/wav")},
        data={
            "app": "com.google.chrome",
            "app_site": "mail.google.com",
            "app_detail": "Inbox (12) - Gmail",
        },
        headers={"X-SunoFlow-Device-Key": f"Bearer {KEY}"},
    )

    assert resp.status_code == 200
    assert seen["app"] == "com.google.chrome"
    assert seen["app_site"] == "mail.google.com"
    assert seen["app_detail"] == "Inbox (12) - Gmail"


def test_no_app_fields_is_the_request_it_always_was(client, monkeypatch):
    """A client too old to send them, or a dictation where nothing could be read,
    must still clean normally."""
    seen = {}

    def fake(text, context="", recent=None, screen="", key="", dictionary=None,
             tone="", app="", app_site="", app_detail=""):
        seen.update(app=app, app_site=app_site, app_detail=app_detail)
        return text

    monkeypatch.setattr(app_module, "clean_with_gateway", fake)
    assert _post(client).status_code == 200
    assert seen == {"app": "", "app_site": "", "app_detail": ""}
