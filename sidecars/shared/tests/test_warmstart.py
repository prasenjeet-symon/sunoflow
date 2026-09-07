"""Tests for the warm-start STT controller — the cloud→local migration logic.

Pure-Python, no FastAPI/model/network deps — run with ``pytest sidecars/shared/tests``.
These pin the routing state machine and the two cutover gates (speed + quality)
that decide when on-device transcription is trusted.
"""
import os
import sys
import tempfile

# Make ``sidecars.*`` importable when run from the repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__)))))

from sidecars.shared.warmstart import (  # noqa: E402
    DEFAULT_MIN_AGREEMENT,
    ROUTE_CLOUD,
    ROUTE_LOCAL,
    ROUTE_SHADOW,
    ROUTE_WAIT,
    WarmStartController,
    real_time_factor,
    word_agreement,
)


# --- routing ------------------------------------------------------------------

def test_route_disabled_ignores_consent():
    c = WarmStartController(enabled=False)
    # No cloud STT configured: local when ready, wait otherwise — never cloud.
    assert c.route(consent=True, model_loaded=False) == ROUTE_WAIT
    assert c.route(consent=True, model_loaded=True) == ROUTE_LOCAL


def test_route_no_consent():
    c = WarmStartController(enabled=True)
    assert c.route(consent=False, model_loaded=False) == ROUTE_WAIT
    assert c.route(consent=False, model_loaded=True) == ROUTE_LOCAL


def test_route_consent_cloud_then_shadow():
    c = WarmStartController(enabled=True)
    assert c.route(consent=True, model_loaded=False) == ROUTE_CLOUD
    assert c.route(consent=True, model_loaded=True) == ROUTE_SHADOW


def test_route_local_after_cutover_is_sticky():
    c = WarmStartController(enabled=True, min_samples=1, rtf_target=1.0, min_agreement=0.5)
    assert c.record_shadow(rtf=0.2, agreement=0.95) is True
    # Even with consent on and the model briefly unloaded, we never reopen cloud.
    assert c.route(consent=True, model_loaded=False) == ROUTE_LOCAL
    assert c.route(consent=True, model_loaded=True) == ROUTE_LOCAL


# --- word_agreement -----------------------------------------------------------

def test_agreement_identical_and_empty():
    assert word_agreement("hello world", "hello world") == 1.0
    assert word_agreement("", "") == 1.0
    assert word_agreement("", "words") == 0.0
    assert word_agreement("words", "") == 0.0


def test_agreement_ignores_case_and_punctuation():
    assert word_agreement("Hello, world!", "hello world") == 1.0


def test_agreement_partial_between_zero_and_one():
    a = word_agreement("the quick brown fox", "the quick red fox")
    assert 0.0 < a < 1.0


# --- real_time_factor ---------------------------------------------------------

def test_rtf_basic_and_edges():
    assert real_time_factor(1.0, 2.0) == 0.5
    assert real_time_factor(2.0, 1.0) == 2.0
    assert real_time_factor(1.0, 0) == float("inf")
    assert real_time_factor(1.0, None) == float("inf")
    # A negative wall clock (clock skew) clamps to 0 rather than passing as < 0.
    assert real_time_factor(-5.0, 1.0) == 0.0


# --- cutover gates ------------------------------------------------------------

def test_no_cutover_below_min_samples():
    c = WarmStartController(enabled=True, min_samples=3, rtf_target=1.0, min_agreement=0.8)
    assert c.record_shadow(rtf=0.1, agreement=0.99) is False
    assert c.record_shadow(rtf=0.1, agreement=0.99) is False
    assert c.cut_over is False
    # The third good sample crosses the line.
    assert c.record_shadow(rtf=0.1, agreement=0.99) is True
    assert c.cut_over is True


def test_no_cutover_when_agreement_too_low():
    c = WarmStartController(enabled=True, min_samples=3, rtf_target=1.0, min_agreement=0.8)
    for _ in range(5):
        c.record_shadow(rtf=0.1, agreement=0.5)  # fast but wrong
    assert c.cut_over is False


def test_no_cutover_when_too_slow():
    c = WarmStartController(enabled=True, min_samples=3, rtf_target=1.0, min_agreement=0.8)
    for _ in range(5):
        c.record_shadow(rtf=3.0, agreement=0.99)  # accurate but slower than real time
    assert c.cut_over is False


def test_median_tolerates_one_bad_sample():
    c = WarmStartController(enabled=True, min_samples=3, rtf_target=1.0, min_agreement=0.8)
    c.record_shadow(rtf=0.1, agreement=0.95)
    c.record_shadow(rtf=0.1, agreement=0.40)  # one noisy clip
    # Median of the last 3 (0.95, 0.40, 0.95) = 0.95 ≥ 0.8 → cut over.
    assert c.record_shadow(rtf=0.1, agreement=0.95) is True


def test_record_shadow_after_cutover_is_noop():
    c = WarmStartController(enabled=True, min_samples=1, rtf_target=1.0, min_agreement=0.5)
    assert c.record_shadow(rtf=0.2, agreement=0.9) is True
    assert c.record_shadow(rtf=0.2, agreement=0.9) is False  # already cut over


def test_force_local():
    c = WarmStartController(enabled=True)
    assert c.cut_over is False
    c.force_local()
    assert c.cut_over is True
    assert c.route(consent=True, model_loaded=True) == ROUTE_LOCAL


# --- persistence --------------------------------------------------------------

def test_cutover_persists_across_restart():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "sub", "warmstart.json")  # nested dir must be created
        c1 = WarmStartController(enabled=True, min_samples=1, rtf_target=1.0,
                                 min_agreement=0.5, state_path=path)
        assert c1.record_shadow(rtf=0.2, agreement=0.9) is True
        # A fresh controller pointed at the same file starts already cut over.
        c2 = WarmStartController(enabled=True, state_path=path)
        assert c2.cut_over is True
        assert c2.route(consent=True, model_loaded=False) == ROUTE_LOCAL


def test_missing_state_file_starts_not_cut_over():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "nope.json")
        c = WarmStartController(enabled=True, state_path=path)
        assert c.cut_over is False


def test_corrupt_state_file_is_ignored():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "warmstart.json")
        with open(path, "w") as f:
            f.write("{not valid json")
        c = WarmStartController(enabled=True, state_path=path)
        assert c.cut_over is False


# --- from_env + snapshot ------------------------------------------------------

def test_from_env_reads_gates(monkeypatch=None):
    os.environ["SUNOFLOW_STT_RTF_TARGET"] = "0.5"
    os.environ["SUNOFLOW_STT_MIN_AGREEMENT"] = "0.9"
    os.environ["SUNOFLOW_STT_MIN_SAMPLES"] = "2"
    try:
        c = WarmStartController.from_env(enabled=True)
        snap = c.snapshot()
        assert snap["rtf_target"] == 0.5
        assert snap["min_agreement"] == 0.9
        assert snap["min_samples"] == 2
    finally:
        for k in ("SUNOFLOW_STT_RTF_TARGET", "SUNOFLOW_STT_MIN_AGREEMENT", "SUNOFLOW_STT_MIN_SAMPLES"):
            os.environ.pop(k, None)


def test_from_env_defaults_when_unset():
    c = WarmStartController.from_env(enabled=True)
    assert c.snapshot()["min_agreement"] == DEFAULT_MIN_AGREEMENT


def test_snapshot_reports_live_route_and_progress():
    c = WarmStartController(enabled=True, min_samples=3, rtf_target=1.0, min_agreement=0.8)
    c.record_shadow(rtf=0.2, agreement=0.9)
    snap = c.snapshot(consent=True, model_loaded=True)
    assert snap["stt_mode"] == ROUTE_SHADOW
    assert snap["samples"] == 1
    assert snap["cut_over"] is False
    assert snap["median_rtf"] == 0.2
