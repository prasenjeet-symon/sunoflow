"""Tests for the Windows ONNX adapter's platform-specific logic.

These run on any OS (including the macOS dev box) because the adapter lazy-imports
``onnx_asr`` / ``onnxruntime`` only inside ``load()`` / ``transcribe_file()`` —
which we don't call here. We exercise the download-manager state machine, the
provider selection, and the file manifest instead.

Run: ``python -m pytest sidecars/windows/tests/test_adapter.py`` from the repo
root (needs the repo root on sys.path, which the test package's __init__ adds).
"""
import os
import sys
from pathlib import Path

import pytest

_REPO_ROOT = str(Path(__file__).resolve().parents[3])
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from sidecars.windows.adapter import (
    HF_REPO,
    MODEL_DIR,
    MODEL_FILES,
    ParakeetOnnxAdapter,
)


# --- File manifest ------------------------------------------------------------

def test_model_files_complete():
    """The ONNX export needs all six files to be considered present."""
    assert set(MODEL_FILES) == {
        "config.json",
        "encoder-model.onnx",
        "encoder-model.onnx.data",
        "decoder_joint-model.onnx",
        "nemo128.onnx",
        "vocab.txt",
    }


def test_model_files_include_external_weights():
    """The encoder weights live in a separate .data file — without it the
    InferenceSession fails to load. This is the easiest thing to forget."""
    assert "encoder-model.onnx.data" in MODEL_FILES


def test_hf_base_resolves_to_istupakov_repo():
    """Download URLs must point at the onnx-asr-compatible v3 export."""
    from sidecars.windows.adapter import HF_BASE
    assert HF_BASE == "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main"


# --- is_present ---------------------------------------------------------------

def test_is_present_false_when_dir_missing(tmp_path, monkeypatch):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path / "nope"))
    a = ParakeetOnnxAdapter()
    assert a.is_present() is False


def test_is_present_true_when_all_files_exist(tmp_path, monkeypatch):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")
    a = ParakeetOnnxAdapter()
    assert a.is_present() is True


def test_is_present_false_when_one_file_missing(tmp_path, monkeypatch):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")
    (tmp_path / MODEL_FILES[0]).unlink()
    a = ParakeetOnnxAdapter()
    assert a.is_present() is False


# --- Provider selection -------------------------------------------------------

class _FakeRT:
    def __init__(self, providers):
        self._providers = providers

    def get_available_providers(self):
        return list(self._providers)


def test_select_providers_prefers_directml():
    a = ParakeetOnnxAdapter()
    rt = _FakeRT(["CPUExecutionProvider", "DmlExecutionProvider"])
    assert a._select_providers(rt) == ["DmlExecutionProvider", "CPUExecutionProvider"]


def test_select_providers_falls_back_to_cpu_without_directml():
    a = ParakeetOnnxAdapter()
    rt = _FakeRT(["CPUExecutionProvider"])
    assert a._select_providers(rt) == ["CPUExecutionProvider"]


# --- Download manager state machine ------------------------------------------

def test_start_download_rejects_when_already_running():
    a = ParakeetOnnxAdapter()
    a._dl_state["active"] = True
    result = a.start_download()
    assert result == {"started": False, "reason": "already_running"}


def test_start_download_rejects_when_already_present_and_loaded(monkeypatch, tmp_path):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")
    a = ParakeetOnnxAdapter()
    a.model = object()  # loaded
    result = a.start_download()
    assert result == {"started": False, "reason": "already_present"}


def test_start_download_spawns_thread(monkeypatch, tmp_path):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    started_threads = []

    def fake_thread(target=None, **kw):
        started_threads.append(target)
        class _T:
            def start(self_inner):
                pass
        return _T()

    monkeypatch.setattr("sidecars.windows.adapter.threading.Thread", fake_thread)
    a = ParakeetOnnxAdapter()
    result = a.start_download()
    assert result == {"started": True}
    assert len(started_threads) == 1


def test_status_snapshot_shape():
    a = ParakeetOnnxAdapter()
    snap = a.status_snapshot()
    # All fields the contract's /model/status reads.
    for key in ("active", "phase", "current_file", "downloaded", "file_total",
                "overall_done", "overall_total", "error", "model_dir", "model_id"):
        assert key in snap, f"missing {key}"
    assert snap["overall_total"] == len(MODEL_FILES)
    assert snap["model_id"] == HF_REPO
    assert snap["model_dir"] == MODEL_DIR


def test_fresh_adapter_reports_no_load_error_and_no_runtime():
    """Nothing has been attempted yet, so neither field may claim otherwise —
    an empty load_error is what lets the client say "not downloaded" rather
    than inventing a failure."""
    a = ParakeetOnnxAdapter()
    assert a.load_error == ""
    assert a.runtime_label() == ""


def test_run_download_counts_existing_files(monkeypatch, tmp_path):
    """Files already on disk are skipped but still counted in overall_done —
    this is what makes a resumed download report correct progress."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    # Pre-place the first two files so they're "already downloaded".
    for f in MODEL_FILES[:2]:
        (tmp_path / f).write_bytes(b"x")

    a = ParakeetOnnxAdapter()
    # Pin the space preflight: what this test is about is the resume count, and
    # leaving it live would make the result depend on the host's free disk.
    monkeypatch.setattr(a, "_disk_shortfall", lambda: "")
    # Stub _download_file to record calls (should only happen for the missing files).
    downloaded = []
    def fake_dl(url, dest):
        downloaded.append(os.path.basename(dest))
        Path(dest).write_bytes(b"x")
    monkeypatch.setattr(a, "_download_file", fake_dl)
    # Stub load() so the thread doesn't try to import onnx_asr.
    monkeypatch.setattr(a, "load", lambda: setattr(a, "model", object()))

    a._run_download()

    # Only the 4 missing files should have been fetched.
    assert sorted(downloaded) == sorted(MODEL_FILES[2:])
    assert a._dl_state["overall_done"] == len(MODEL_FILES)
    assert a._dl_state["phase"] == "done"
    assert a._dl_state["active"] is False
    assert a.model is not None  # load() was called


def test_run_download_records_error(monkeypatch, tmp_path):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))

    a = ParakeetOnnxAdapter()
    monkeypatch.setattr(a, "_disk_shortfall", lambda: "")
    def boom(url, dest):
        raise RuntimeError("network down")
    monkeypatch.setattr(a, "_download_file", boom)

    a._run_download()

    assert a._dl_state["phase"] == "error"
    assert a._dl_state["active"] is False
    assert "network down" in a._dl_state["error"]
    assert a.model is None  # never loaded


# --- load() soft-fail ---------------------------------------------------------

def test_load_soft_fails_when_files_missing(tmp_path, monkeypatch):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path / "empty"))
    a = ParakeetOnnxAdapter()
    a.load()  # must not raise
    assert a.model is None


def test_load_attempts_import_when_files_present(tmp_path, monkeypatch):
    """When files exist, load() must try to import onnx_asr and call load_model.
    We inject a fake onnx_asr + onnxruntime so the test runs without the deps."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")

    import sys, types
    fake_asr = types.ModuleType("onnx_asr")
    fake_rt = types.ModuleType("onnxruntime")

    captured = {}

    class _FakeModel:
        def recognize(self, path):
            return "fake transcript"

    def fake_load_model(model_id, path=None, providers=None):
        captured["model_id"] = model_id
        captured["path"] = path
        captured["providers"] = providers
        return _FakeModel()

    fake_asr.load_model = fake_load_model
    fake_rt.get_available_providers = lambda: ["DmlExecutionProvider", "CPUExecutionProvider"]
    monkeypatch.setitem(sys.modules, "onnx_asr", fake_asr)
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_rt)

    a = ParakeetOnnxAdapter()
    a.load()

    assert a.model is not None
    assert captured["model_id"] == "nemo-parakeet-tdt-0.6b-v3"
    assert captured["path"] == str(tmp_path)
    assert captured["providers"] == ["DmlExecutionProvider", "CPUExecutionProvider"]
    # transcribe_file delegates to recognize().
    assert a.transcribe_file(str(tmp_path / "x.wav")) == "fake transcript"

def test_load_failure_after_download_is_not_reported_as_a_download_failure(tmp_path, monkeypatch):
    """A model that downloads and then fails to load must say so.

    This shipped as a real bug: PyInstaller left out the package metadata that
    ``onnx_asr`` reads its own version from, so ``import onnx_asr`` raised, and
    because loading happened inside the download's try block the dashboard
    announced "Download failed" over 2.5 GB of perfectly good files. The user's
    only obvious move was to download all of it again, which could not help.
    """
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")

    a = ParakeetOnnxAdapter()
    monkeypatch.setattr(a, "_disk_shortfall", lambda: "")
    # Every file is already present, so the download loop is a no-op and the
    # only thing left to fail is the load.
    monkeypatch.setattr(
        a, "load",
        lambda: (_ for _ in ()).throw(Exception("No package metadata was found for onnx-asr")),
    )

    a._run_download()

    snap = a.status_snapshot()
    assert snap["phase"] == "error"
    assert snap["active"] is False
    # The message must point at loading, not at the download.
    assert "could not start" in snap["error"]
    assert "No package metadata" in snap["error"]
    # And every file is still counted as fetched, so the client can offer
    # "start the engine" rather than "download it all again".
    assert snap["overall_done"] == len(MODEL_FILES)


# --- load() proves the model can actually run ---------------------------------

def _install_fake_engine(monkeypatch, *, recognize, providers=None):
    """Inject a fake onnx_asr + onnxruntime so load() runs without the deps.

    ``recognize`` is the callable the fake model exposes — the hook the smoke
    pass goes through, and therefore the hook for making inference fail.
    """
    import sys, types
    fake_asr = types.ModuleType("onnx_asr")
    fake_rt = types.ModuleType("onnxruntime")

    class _FakeModel:
        def recognize(self, path):
            return recognize(path)

    fake_asr.load_model = lambda model_id, path=None, providers=None: _FakeModel()
    fake_rt.get_available_providers = lambda: (
        providers if providers is not None
        else ["DmlExecutionProvider", "CPUExecutionProvider"]
    )
    monkeypatch.setitem(sys.modules, "onnx_asr", fake_asr)
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_rt)


def _present_model_dir(tmp_path, monkeypatch):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")


def test_load_runs_a_real_clip_through_the_model(tmp_path, monkeypatch):
    """Sessions that construct are not sessions that run — so load() must put
    audio through the model before it calls it loaded."""
    _present_model_dir(tmp_path, monkeypatch)
    seen = []

    def recognize(path):
        # A readable 16 kHz mono WAV of real length, not a placeholder: this is
        # the whole point of the pass.
        import wave
        with wave.open(path, "rb") as w:
            seen.append((w.getnchannels(), w.getsampwidth(), w.getframerate(),
                         w.getnframes()))
        return ""

    _install_fake_engine(monkeypatch, recognize=recognize)
    a = ParakeetOnnxAdapter()
    a.load()

    assert len(seen) == 1, "load() must verify with exactly one forward pass"
    channels, width, rate, frames = seen[0]
    assert (channels, width, rate) == (1, 2, 16000)
    assert frames / rate >= 0.5, "clip too short to exercise the encoder"
    assert a.is_loaded() is True
    assert a.load_error == ""


def test_load_rejects_a_model_that_loads_but_cannot_run(tmp_path, monkeypatch):
    """The failure this exists for: DirectML gone, weights truncated. The
    session builds, the first Run throws. Reporting that model as ready made
    every dictation paste nothing, silently and forever."""
    _present_model_dir(tmp_path, monkeypatch)
    _install_fake_engine(
        monkeypatch,
        recognize=lambda path: (_ for _ in ()).throw(
            RuntimeError("D3D12 device removed")),
    )

    a = ParakeetOnnxAdapter()
    with pytest.raises(RuntimeError):
        a.load()

    assert a.is_loaded() is False, "a model that cannot run must not read as loaded"
    assert "D3D12 device removed" in a.load_error
    assert a.runtime_label() == ""


def test_load_records_why_it_failed_and_strips_urls(tmp_path, monkeypatch):
    _present_model_dir(tmp_path, monkeypatch)
    _install_fake_engine(
        monkeypatch,
        recognize=lambda path: (_ for _ in ()).throw(
            Exception("fetch of https://huggingface.co/secret/path failed")),
    )

    a = ParakeetOnnxAdapter()
    with pytest.raises(Exception):
        a.load()

    assert "huggingface.co" not in a.load_error
    assert "[model URL]" in a.load_error


def test_missing_files_are_not_recorded_as_a_load_error(tmp_path, monkeypatch):
    """"Nothing downloaded yet" is a different state from "it will not start",
    and the dashboard shows a Download button for one and an error for the
    other."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path / "empty"))
    a = ParakeetOnnxAdapter()
    a.load()
    assert a.load_error == ""


def test_load_reports_the_runtime_it_verified_on(tmp_path, monkeypatch):
    _present_model_dir(tmp_path, monkeypatch)
    _install_fake_engine(monkeypatch, recognize=lambda path: "")
    a = ParakeetOnnxAdapter()
    a.load()
    assert a.runtime_label() == "GPU (DirectML)"


def test_load_reports_cpu_when_directml_is_absent(tmp_path, monkeypatch):
    """The dashboard states transcription runs on the GPU. On a box without
    DirectML it silently doesn't, and the user is owed that fact."""
    _present_model_dir(tmp_path, monkeypatch)
    _install_fake_engine(monkeypatch, recognize=lambda path: "",
                         providers=["CPUExecutionProvider"])
    a = ParakeetOnnxAdapter()
    a.load()
    assert a.runtime_label() == "CPU"


def test_a_second_load_clears_a_previous_failure(tmp_path, monkeypatch):
    """Retry has to be able to succeed — a stale load_error would leave the
    dashboard showing an error over a working model."""
    _present_model_dir(tmp_path, monkeypatch)
    _install_fake_engine(
        monkeypatch,
        recognize=lambda path: (_ for _ in ()).throw(RuntimeError("out of memory")),
    )
    a = ParakeetOnnxAdapter()
    with pytest.raises(RuntimeError):
        a.load()
    assert a.load_error

    _install_fake_engine(monkeypatch, recognize=lambda path: "")
    a.load()
    assert a.load_error == ""
    assert a.is_loaded() is True


# --- Disk space preflight -----------------------------------------------------

def test_disk_shortfall_blocks_a_download_that_cannot_fit(monkeypatch, tmp_path):
    """Running out of disk mid-download truncates the external weights file,
    which then loads clean and fails on first inference — so refuse up front."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    import collections
    usage = collections.namedtuple("usage", "total used free")
    monkeypatch.setattr("sidecars.windows.adapter.shutil.disk_usage",
                        lambda p: usage(500_000_000_000, 499_000_000_000, 1_000_000_000))

    a = ParakeetOnnxAdapter()
    assert "Not enough disk space" in a._disk_shortfall()

    fetched = []
    monkeypatch.setattr(a, "_download_file", lambda url, dest: fetched.append(dest))
    a._run_download()

    assert fetched == [], "no bytes may be fetched when there is no room for them"
    assert a._dl_state["phase"] == "error"
    assert a._dl_state["active"] is False
    assert "disk space" in a._dl_state["error"]


def test_disk_shortfall_counts_only_the_files_still_missing(monkeypatch, tmp_path):
    """A resumed download already has most of the 2.5 GB on disk and must not
    be refused for space it is not about to use."""
    from sidecars.windows.adapter import MODEL_BYTES_TOTAL
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    # Nearly the whole model is already there.
    (tmp_path / "encoder-model.onnx.data").write_bytes(b"x" * 4096)
    monkeypatch.setattr("sidecars.windows.adapter.os.path.getsize",
                        lambda p: MODEL_BYTES_TOTAL - 1_000_000)

    import collections
    usage = collections.namedtuple("usage", "total used free")
    monkeypatch.setattr("sidecars.windows.adapter.shutil.disk_usage",
                        lambda p: usage(500_000_000_000, 0, 400_000_000))

    a = ParakeetOnnxAdapter()
    assert a._disk_shortfall() == ""


def test_disk_shortfall_allows_the_download_when_the_check_itself_fails(monkeypatch, tmp_path):
    """An unreadable drive is not evidence of a full one. Blocking here would
    turn a diagnostic into a wall."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    monkeypatch.setattr("sidecars.windows.adapter.shutil.disk_usage",
                        lambda p: (_ for _ in ()).throw(OSError("no such device")))
    a = ParakeetOnnxAdapter()
    assert a._disk_shortfall() == ""
