"""A model that is on disk but will not start has to be able to say so.

The failure these pin: the app factory caught a startup load exception, printed
it, and moved on. ``/model/status`` then reported ``model_present=true,
model_loaded=false, phase="idle", error=""`` — indistinguishable from a model
that had simply never been downloaded, except that the dashboard's suggested fix
(restart the engine) was aimed at an engine that was already running. The real
reason lived only in a log file.
"""
import pytest
from fastapi.testclient import TestClient

from sidecars.shared.app import SttAdapter, create_app


class PresentButBrokenAdapter(SttAdapter):
    """Files all downloaded; loading them raises every time."""

    def __init__(self, message="D3D12 device removed"):
        self.message = message
        self.attempts = 0

    def is_loaded(self):
        return False

    def is_present(self):
        return True

    def load(self):
        self.attempts += 1
        raise RuntimeError(self.message)

    def transcribe_file(self, path):
        raise AssertionError("not reachable with no model loaded")

    def status_snapshot(self):
        return {"active": False, "phase": "idle", "overall_total": 6}

    def start_download(self):
        return {"started": True}


class NeverDownloadedAdapter(PresentButBrokenAdapter):
    def is_present(self):
        return False

    def load(self):
        # Nothing on disk is not a failure — it is the state a fresh install is
        # supposed to be in.
        self.attempts += 1


def _client(adapter, tmp_path):
    return TestClient(create_app(adapter, str(tmp_path / "corrections.json")))


def test_startup_load_failure_is_recorded_not_just_printed(tmp_path):
    adapter = PresentButBrokenAdapter()
    with _client(adapter, tmp_path) as client:
        assert adapter.attempts == 1, "the app must still try to load at startup"
        body = client.get("/model/status").json()

    assert body["model_present"] is True
    assert body["model_loaded"] is False
    assert "D3D12 device removed" in body["load_error"]


def test_a_load_failure_is_not_dressed_up_as_a_download_failure(tmp_path):
    """``error`` invites the user to download 2.5 GB again. For a model that
    downloaded fine and then refused to start, that cannot help."""
    with _client(PresentButBrokenAdapter(), tmp_path) as client:
        body = client.get("/model/status").json()

    assert body["error"] == ""
    assert body["load_error"] != ""


def test_health_carries_the_load_error_too(tmp_path):
    """The tray polls /health and nothing else. Without this it can only say
    "download the model" about a model that is already there."""
    with _client(PresentButBrokenAdapter(), tmp_path) as client:
        body = client.get("/health").json()

    assert body["status"] == "ok"
    assert body["model_loaded"] is False
    assert body["model_present"] is True
    assert "D3D12 device removed" in body["load_error"]


def test_a_model_that_was_never_downloaded_reports_no_error(tmp_path):
    """The two states need different words and different buttons, so they must
    not collapse into one."""
    with _client(NeverDownloadedAdapter(), tmp_path) as client:
        status = client.get("/model/status").json()
        health = client.get("/health").json()

    assert status["model_present"] is False
    assert status["load_error"] == ""
    assert health["load_error"] == ""


def test_the_sidecar_still_serves_when_the_model_will_not_load(tmp_path):
    """Soft-fail is the point: the dashboard has to stay reachable to show the
    problem and offer the retry."""
    with _client(PresentButBrokenAdapter(), tmp_path) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/model/status").status_code == 200


def test_status_reports_the_runtime_the_adapter_verified_on(tmp_path):
    class CpuAdapter(NeverDownloadedAdapter):
        def is_present(self):
            return True

        def is_loaded(self):
            return True

        def load(self):
            pass

        def runtime_label(self):
            return "CPU"

    with _client(CpuAdapter(), tmp_path) as client:
        assert client.get("/model/status").json()["runtime"] == "CPU"


def test_runtime_is_empty_when_the_adapter_does_not_know(tmp_path):
    with _client(NeverDownloadedAdapter(), tmp_path) as client:
        assert client.get("/model/status").json()["runtime"] == ""


@pytest.mark.parametrize("field", ["load_error", "runtime"])
def test_contract_fields_are_always_present(tmp_path, field):
    """Clients read these unconditionally; an absent field would deserialize to
    a default that reads as "fine"."""
    with _client(NeverDownloadedAdapter(), tmp_path) as client:
        assert field in client.get("/model/status").json()
