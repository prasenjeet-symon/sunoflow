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
    MIN_VRAM_BYTES_FP32,
    MODEL_DIR,
    MODEL_FILES,
    VARIANT_FP32,
    VARIANT_INT8,
    VARIANTS,
    ParakeetOnnxAdapter,
)

INT8_FILES = VARIANTS[VARIANT_INT8]["files"]


@pytest.fixture(autouse=True)
def _no_real_downloads(monkeypatch):
    """Nothing in this suite may reach the network.

    Not hypothetical. When variant selection landed, a test that placed the
    fp32 files and expected the download loop to no-op began resolving the int8
    manifest instead, found none of it on disk, and started pulling 652 MB from
    HuggingFace. A class-level guard turns that into an immediate failure; the
    tests that do exercise the loop stub the *instance* method, which wins.
    """
    def _refuse(self, url, dest):
        raise AssertionError(f"test attempted a real download: {url}")
    monkeypatch.setattr(ParakeetOnnxAdapter, "_download_file", _refuse)


@pytest.fixture(autouse=True)
def _pin_variant(monkeypatch):
    """Pin fp32 so the manifest under test does not depend on the host.

    Most tests here place the fp32 files and assert against MODEL_FILES.
    Unpinned, the answer would differ between a dev Mac, CI, and a Windows box
    with a discrete GPU. The variant-selection tests below drop this pin.
    """
    monkeypatch.setenv("SUNOFLOW_MODEL_VARIANT", "fp32")


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
                "overall_done", "overall_total", "error", "model_dir", "model_id",
                "variant", "variant_label", "variant_reason", "download_bytes"):
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

    def fake_load_model(model_id, path=None, quantization=None, providers=None):
        captured["model_id"] = model_id
        captured["path"] = path
        captured["quantization"] = quantization
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
    # fp32 resolves the unquantized graphs — onnx-asr globs the literal
    # encoder-model.onnx for None and encoder-model?int8.onnx for "int8".
    assert captured["quantization"] is None
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

    calls = {}

    def _load(model_id, path=None, quantization=None, providers=None):
        calls.update(model_id=model_id, path=path,
                     quantization=quantization, providers=providers)
        return _FakeModel()

    fake_asr.load_model = _load
    fake_rt.get_available_providers = lambda: (
        providers if providers is not None
        else ["DmlExecutionProvider", "CPUExecutionProvider"]
    )
    monkeypatch.setitem(sys.modules, "onnx_asr", fake_asr)
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_rt)
    return calls


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


# --- Variant manifests --------------------------------------------------------

def test_int8_encoder_has_no_external_data_sibling():
    """The fp32 encoder splits into .onnx + .onnx.data; the int8 one is 652 MB,
    under the 2 GB protobuf ceiling, so it is self-contained. Requiring a .data
    file here would make every int8 install look permanently incomplete."""
    assert "encoder-model.int8.onnx" in INT8_FILES
    assert not any(f.endswith(".data") for f in INT8_FILES)


def test_variants_do_not_share_encoder_filenames():
    """onnx-asr resolves fp32 by the literal name and int8 by a glob. The names
    must stay distinct so both can sit in MODEL_DIR without colliding — that is
    what lets a box keep an fp32 install it already paid to download."""
    fp32_only = set(MODEL_FILES) - set(INT8_FILES)
    int8_only = set(INT8_FILES) - set(MODEL_FILES)
    assert "encoder-model.onnx" in fp32_only
    assert "encoder-model.int8.onnx" in int8_only


def test_int8_is_the_smaller_download_by_a_wide_margin():
    """The whole reason the int8 path exists for constrained machines."""
    assert VARIANTS[VARIANT_INT8]["bytes"] < VARIANTS[VARIANT_FP32]["bytes"] / 3


# --- Hardware probe -----------------------------------------------------------

def _probe(monkeypatch, *, providers, vram):
    """An adapter whose probe sees exactly ``providers`` and ``vram``."""
    monkeypatch.delenv("SUNOFLOW_MODEL_VARIANT", raising=False)
    monkeypatch.setattr("sidecars.windows.adapter._dedicated_vram_bytes",
                        lambda: vram)
    return ParakeetOnnxAdapter(), _FakeRT(providers)


def test_chooses_int8_when_there_is_no_directml(monkeypatch):
    """No DX12 GPU is the case int8 exists for: it is the CPU path, not a
    lesser GPU path."""
    a, rt = _probe(monkeypatch, providers=["CPUExecutionProvider"], vram=None)
    variant, reason = a._choose_variant(rt)
    assert variant == VARIANT_INT8
    assert "DirectML" in reason


def test_chooses_int8_when_the_gpu_is_too_small(monkeypatch):
    a, rt = _probe(monkeypatch,
                   providers=["DmlExecutionProvider", "CPUExecutionProvider"],
                   vram=2 * 1024 ** 3)
    variant, reason = a._choose_variant(rt)
    assert variant == VARIANT_INT8
    assert "memory" in reason


def test_chooses_fp32_on_a_gpu_with_headroom(monkeypatch):
    a, rt = _probe(monkeypatch,
                   providers=["DmlExecutionProvider", "CPUExecutionProvider"],
                   vram=8 * 1024 ** 3)
    variant, _ = a._choose_variant(rt)
    assert variant == VARIANT_FP32


def test_unreadable_vram_chooses_the_safe_variant(monkeypatch):
    """The two mistakes are not symmetric. An unnecessary int8 costs a little
    accuracy; an unnecessary fp32 costs 2.5 GB that then will not run."""
    a, rt = _probe(monkeypatch,
                   providers=["DmlExecutionProvider", "CPUExecutionProvider"],
                   vram=None)
    variant, reason = a._choose_variant(rt)
    assert variant == VARIANT_INT8
    assert "could not read" in reason


def test_exactly_at_the_vram_bar_chooses_fp32(monkeypatch):
    a, rt = _probe(monkeypatch,
                   providers=["DmlExecutionProvider", "CPUExecutionProvider"],
                   vram=MIN_VRAM_BYTES_FP32)
    assert a._choose_variant(rt)[0] == VARIANT_FP32


def test_a_capable_gpu_with_no_disk_room_still_gets_int8(monkeypatch, tmp_path):
    """Room on the GPU is not room on the disk. Catching it here turns a
    refusal the user cannot act on into a smaller model that just works."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    import collections
    usage = collections.namedtuple("usage", "total used free")
    # Enough for int8 + headroom, nowhere near enough for fp32.
    monkeypatch.setattr("sidecars.windows.adapter.shutil.disk_usage",
                        lambda p: usage(10 ** 12, 0, 1_200_000_000))
    a, rt = _probe(monkeypatch,
                   providers=["DmlExecutionProvider", "CPUExecutionProvider"],
                   vram=8 * 1024 ** 3)
    variant, reason = a._choose_variant(rt)
    assert variant == VARIANT_INT8
    assert "disk space" in reason


def test_env_override_pins_the_variant_without_probing(monkeypatch):
    """Support needs a pin that works on a box where importing onnxruntime is
    itself the problem — so the override is read before that import."""
    monkeypatch.setenv("SUNOFLOW_MODEL_VARIANT", "int8")
    monkeypatch.setattr("sidecars.windows.adapter._dedicated_vram_bytes",
                        lambda: (_ for _ in ()).throw(
                            AssertionError("probe must not run")))
    a = ParakeetOnnxAdapter()
    variant, reason = a._ensure_choice()
    assert variant == VARIANT_INT8
    assert "SUNOFLOW_MODEL_VARIANT" in reason


def test_a_bad_env_override_is_ignored(monkeypatch):
    monkeypatch.setenv("SUNOFLOW_MODEL_VARIANT", "fp16")
    a = ParakeetOnnxAdapter()
    variant, reason = a._ensure_choice()
    assert variant in VARIANTS
    assert "SUNOFLOW_MODEL_VARIANT" not in reason


def test_an_unimportable_runtime_falls_back_to_int8(monkeypatch):
    """onnxruntime failing to import has shipped before (PyInstaller metadata).
    It must not be read as licence to commit the box to the big download."""
    import sys
    monkeypatch.delenv("SUNOFLOW_MODEL_VARIANT", raising=False)
    monkeypatch.setitem(sys.modules, "onnxruntime", None)  # import raises
    a = ParakeetOnnxAdapter()
    variant, reason = a._ensure_choice()
    assert variant == VARIANT_INT8
    assert "probe" in reason


def test_the_probe_runs_once_and_is_cached(monkeypatch):
    """/model/status is polled continuously and the probe reads the registry."""
    monkeypatch.delenv("SUNOFLOW_MODEL_VARIANT", raising=False)
    calls = []

    def counting_vram():
        calls.append(1)
        return 8 * 1024 ** 3

    monkeypatch.setattr("sidecars.windows.adapter._dedicated_vram_bytes",
                        counting_vram)
    import sys, types
    fake_rt = types.ModuleType("onnxruntime")
    fake_rt.get_available_providers = lambda: ["DmlExecutionProvider"]
    monkeypatch.setitem(sys.modules, "onnxruntime", fake_rt)

    a = ParakeetOnnxAdapter()
    first = a._ensure_choice()
    assert a._ensure_choice() == first
    assert a._ensure_choice() == first
    assert len(calls) == 1


# --- int8 is the CPU path -----------------------------------------------------

def test_int8_never_runs_on_directml():
    """Dynamic quantization exists to reach the CPU's integer kernels. On
    DirectML it trades accuracy away for no speed and often for less."""
    a = ParakeetOnnxAdapter()
    rt = _FakeRT(["DmlExecutionProvider", "CPUExecutionProvider"])
    assert a._select_providers(rt, VARIANT_INT8) == ["CPUExecutionProvider"]


def test_fp32_still_prefers_directml():
    a = ParakeetOnnxAdapter()
    rt = _FakeRT(["DmlExecutionProvider", "CPUExecutionProvider"])
    assert a._select_providers(rt, VARIANT_FP32) == [
        "DmlExecutionProvider", "CPUExecutionProvider"]


# --- Presence and loading per variant -----------------------------------------

def _present_int8_dir(tmp_path, monkeypatch):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in INT8_FILES:
        (tmp_path / f).write_bytes(b"x")


def test_a_complete_int8_install_reads_as_present(tmp_path, monkeypatch):
    _present_int8_dir(tmp_path, monkeypatch)
    a = ParakeetOnnxAdapter()
    assert a.is_present() is True
    assert a._installed_variant() == VARIANT_INT8


def test_fp32_wins_when_both_variants_are_on_disk(tmp_path, monkeypatch):
    """A box holding the 2.5 GB set either chose it or predates the choice, and
    starting what is there beats demanding another 670 MB to say the same
    words."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in set(MODEL_FILES) | set(INT8_FILES):
        (tmp_path / f).write_bytes(b"x")
    a = ParakeetOnnxAdapter()
    assert a._installed_variant() == VARIANT_FP32


def test_load_uses_int8_quantization_and_the_cpu(tmp_path, monkeypatch):
    """The load path has to agree with the download: int8 files, int8
    quantization, CPU providers — even where DirectML is available."""
    _present_int8_dir(tmp_path, monkeypatch)
    calls = _install_fake_engine(monkeypatch, recognize=lambda path: "")

    a = ParakeetOnnxAdapter()
    a.load()

    assert calls["quantization"] == "int8"
    assert calls["providers"] == ["CPUExecutionProvider"]
    assert a.runtime_label() == "CPU"
    assert a.is_loaded() is True


def test_load_measures_how_fast_the_machine_actually_is(tmp_path, monkeypatch):
    """The smoke clip runs anyway, so timing it is free — and worth more than
    the VRAM heuristic that picked the variant."""
    _present_model_dir(tmp_path, monkeypatch)
    _install_fake_engine(monkeypatch, recognize=lambda path: "")
    a = ParakeetOnnxAdapter()
    a.load()
    assert a._rtf > 0


# --- Download follows the probe -----------------------------------------------

def test_download_fetches_the_int8_manifest_on_a_weak_box(tmp_path, monkeypatch):
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    monkeypatch.setenv("SUNOFLOW_MODEL_VARIANT", "int8")

    a = ParakeetOnnxAdapter()
    monkeypatch.setattr(a, "_disk_shortfall", lambda: "")
    fetched = []

    def fake_dl(url, dest):
        fetched.append(os.path.basename(dest))
        Path(dest).write_bytes(b"x")

    monkeypatch.setattr(a, "_download_file", fake_dl)
    monkeypatch.setattr(a, "load", lambda: setattr(a, "model", object()))

    a._run_download()

    assert sorted(fetched) == sorted(INT8_FILES)
    assert "encoder-model.onnx.data" not in fetched, "must not pull the 2.4 GB fp32 weights"
    assert a._dl_state["variant"] == VARIANT_INT8
    assert a._dl_state["overall_total"] == len(INT8_FILES)
    assert a._dl_state["phase"] == "done"


def test_an_installed_variant_is_kept_when_the_probe_disagrees(tmp_path, monkeypatch):
    """The bug this pins: with fp32 already on disk but not yet loaded, a box
    that probes as int8 would have quietly fetched a second model alongside the
    first — 670 MB to duplicate something already there."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")
    monkeypatch.setenv("SUNOFLOW_MODEL_VARIANT", "int8")

    a = ParakeetOnnxAdapter()
    monkeypatch.setattr(a, "_disk_shortfall", lambda: "")
    fetched = []
    monkeypatch.setattr(a, "_download_file",
                        lambda url, dest: fetched.append(dest))
    monkeypatch.setattr(a, "load", lambda: setattr(a, "model", object()))

    a._run_download()

    assert fetched == [], "nothing to fetch — a complete model is already here"
    assert a._dl_state["variant"] == VARIANT_FP32
    assert a._dl_state["phase"] == "done"


# --- Status reports the variant -----------------------------------------------

def test_status_reports_the_variant_and_why(monkeypatch):
    monkeypatch.setenv("SUNOFLOW_MODEL_VARIANT", "int8")
    a = ParakeetOnnxAdapter()
    snap = a.status_snapshot()
    assert snap["variant"] == VARIANT_INT8
    assert snap["variant_label"] == "int8"
    assert "SUNOFLOW_MODEL_VARIANT" in snap["variant_reason"]
    assert snap["download_bytes"] == VARIANTS[VARIANT_INT8]["bytes"]
    assert snap["overall_total"] == len(INT8_FILES)


def test_status_describes_the_model_on_disk_not_the_one_probed(tmp_path, monkeypatch):
    """A box carrying an older fp32 install must be described by the model it
    will actually load, with the disagreement spelled out rather than hidden."""
    monkeypatch.setattr("sidecars.windows.adapter.MODEL_DIR", str(tmp_path))
    for f in MODEL_FILES:
        (tmp_path / f).write_bytes(b"x")
    monkeypatch.setenv("SUNOFLOW_MODEL_VARIANT", "int8")

    a = ParakeetOnnxAdapter()
    snap = a.status_snapshot()
    assert snap["variant"] == VARIANT_FP32
    assert "already installed" in snap["variant_reason"]
    assert "int8" in snap["variant_reason"]


# --- Our manifests vs what onnx-asr actually resolves --------------------------

def test_our_manifests_match_what_onnx_asr_looks_for(tmp_path):
    """The load-bearing assumption behind the whole variant split.

    onnx-asr finds model files by globbing: the literal ``encoder-model.onnx``
    for fp32, and ``encoder-model?int8.onnx`` for int8 — where ``?`` is a glob
    wildcard, not a literal, so it matches the ``.`` in the real filename. Two
    ways that could go wrong, both silent until a user hits them:

      * a pattern that matches nothing we download, so a model that transferred
        perfectly fails to load;
      * patterns that overlap, so a directory holding both variants raises
        MoreThanOneModelFileFoundError.

    Both variants are laid down together here, which is exactly the state a box
    ends up in when it keeps an fp32 install and later gains an int8 one.
    """
    pytest.importorskip("onnx_asr")
    from onnx_asr.models.nemo import NemoConformerTdt

    for f in set(MODEL_FILES) | set(INT8_FILES):
        (tmp_path / f).write_bytes(b"x")

    for variant in (VARIANT_FP32, VARIANT_INT8):
        wanted = NemoConformerTdt._get_model_files(VARIANTS[variant]["quantization"])
        assert wanted, f"{variant}: onnx-asr asked for nothing"
        for pattern in wanted.values():
            hits = list(tmp_path.glob(pattern))
            assert len(hits) == 1, (
                f"{variant}: {pattern!r} matched {[h.name for h in hits]}, "
                f"expected exactly one")
            assert hits[0].name in VARIANTS[variant]["files"], (
                f"{variant}: {pattern!r} resolved to {hits[0].name}, which is "
                f"not a file we download for this variant")


def test_the_preprocessor_graph_is_downloaded_for_both_variants():
    """nemo128.onnx is resolved from the model config rather than the file
    manifest onnx-asr reports, so the glob test above cannot see it. It is not
    quantized and both variants need it."""
    assert "nemo128.onnx" in MODEL_FILES
    assert "nemo128.onnx" in INT8_FILES
