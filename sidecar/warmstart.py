"""Warm-start STT controller — cloud-first dictation that migrates to on-device.

The problem this solves: a new install cannot dictate until the local model has
downloaded (~2GB on Mac, ~600MB on Windows). Rather than make the user wait, and
rather than trust the cloud forever (it costs money and sends audio off the
device), the sidecar:

  1. transcribes in the cloud while the local model downloads in the background,
  2. once the model loads, keeps serving the *cloud* result but silently runs the
     local model on the same audio and compares the two,
  3. cuts over to on-device permanently once the local model has proven, over a
     handful of real dictations, that it is both fast enough (real-time factor)
     AND accurate enough (word-level agreement with the cloud reference).

Cloud stays authoritative right up to the cutover, so the user never sees an
unvalidated local transcript. After the cutover the sidecar stops calling the
cloud STT entirely — the whole cloud phase is temporary by design.

This module is deliberately free of FastAPI, the model libraries, and the
network: it is pure decision logic (a state machine + two metrics) so the subtle
part — when is local "good enough"? — can be unit-tested in isolation. The HTTP
handler feeds it (consent, whether the model is loaded, and each local-vs-cloud
comparison) and acts on the route it returns.

Consent is NOT stored here. Whether cloud STT is allowed at all is the user's
per-install choice, which the app sends on each request; the controller only
decides routing given that choice, so a user who revokes consent stops hitting
the cloud on their very next dictation.
"""
import json
import os
import re
import threading
import time
from collections import deque
from difflib import SequenceMatcher

# Routing decisions the handler acts on. Named for what the handler does, not for
# an internal phase, so the call site reads as a dispatch.
ROUTE_WAIT = "wait"      # no cloud allowed and no local model yet → soft-empty (pre-feature behaviour)
ROUTE_CLOUD = "cloud"    # cloud transcribes; local model still downloading
ROUTE_SHADOW = "shadow"  # cloud is authoritative; run local too and compare
ROUTE_LOCAL = "local"    # on-device only; the cloud path is done

# Defaults for the cutover gates. Deliberately conservative on quality and loose
# on speed: Parakeet on Apple Silicon runs many times faster than real time, so
# the real gate is agreement — we do not want to cut over to a local model that
# is fast but transcribes worse than the cloud the user has been getting.
DEFAULT_RTF_TARGET = 1.0    # local must transcribe at least as fast as real time
DEFAULT_MIN_AGREEMENT = 0.80  # word-level similarity to the cloud reference
DEFAULT_MIN_SAMPLES = 3     # consecutive good comparisons required to cut over

_WORD_RE = re.compile(r"\w+")


def _norm_words(s: str) -> list:
    """Lowercased word tokens, punctuation and casing discarded.

    Two transcripts of the same audio differ mostly in punctuation and capitals,
    neither of which the cleanup pass would preserve from the raw text anyway, so
    comparing on bare words measures the substance — did the two engines hear the
    same words — rather than formatting the user never sees.
    """
    return _WORD_RE.findall((s or "").lower())


def word_agreement(a: str, b: str) -> float:
    """Word-level similarity of two transcripts, in [0.0, 1.0].

    1.0 means the same words in the same order; 0.0 means nothing in common. Two
    empty transcripts agree (both heard silence); one empty and one not do not.
    The cloud transcript is the reference, so this answers "how close did local
    come to what the cloud heard?".
    """
    ta, tb = _norm_words(a), _norm_words(b)
    if not ta and not tb:
        return 1.0
    if not ta or not tb:
        return 0.0
    return SequenceMatcher(None, ta, tb, autojunk=False).ratio()


def real_time_factor(wall_seconds: float, audio_seconds: float) -> float:
    """Processing time as a multiple of the audio's duration.

    < 1.0 is faster than real time. Non-positive audio (a clip we could not
    measure) returns infinity, which fails the speed gate rather than passing it
    for free.
    """
    if audio_seconds is None or audio_seconds <= 0:
        return float("inf")
    return max(0.0, float(wall_seconds)) / float(audio_seconds)


def _median(values: list) -> float:
    s = sorted(values)
    n = len(s)
    if n == 0:
        return 0.0
    mid = n // 2
    if n % 2:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2.0


class WarmStartController:
    """Decides how each dictation is transcribed, and when to cut over to local.

    Thread-safe: ``route`` is read on the request path while ``record_shadow``
    may run from a comparison finishing, so all state is guarded by one lock.

    The cutover is one-way and sticky: once local is trusted, it stays trusted
    for the life of the process (and across restarts when ``state_path`` is
    given). Re-validating on every launch would re-spend cloud calls the feature
    exists to stop.
    """

    def __init__(
        self,
        *,
        enabled: bool = True,
        rtf_target: float = DEFAULT_RTF_TARGET,
        min_agreement: float = DEFAULT_MIN_AGREEMENT,
        min_samples: int = DEFAULT_MIN_SAMPLES,
        state_path: str = None,
        clock=time.monotonic,
    ):
        # enabled is the master switch: False when no cloud STT is configured
        # (dev, or a deployment that never turned it on), so the controller
        # degrades to "local when ready, wait otherwise" and never routes cloud.
        self._enabled = enabled
        self._rtf_target = float(rtf_target)
        self._min_agreement = float(min_agreement)
        self._min_samples = max(1, int(min_samples))
        self._state_path = state_path
        self._clock = clock

        self._lock = threading.Lock()
        # Keep a few more than needed so a snapshot can show recent history, but
        # the cutover decision only ever reads the last ``min_samples``.
        self._samples: "deque[dict]" = deque(maxlen=max(self._min_samples * 4, 12))
        self._cut_over = False
        self._cutover_at = None

        self._load_state()

    @classmethod
    def from_env(cls, *, enabled: bool, state_path: str = None, clock=time.monotonic):
        """Build a controller with the cutover gates read from the environment.

        SUNOFLOW_STT_RTF_TARGET / _MIN_AGREEMENT / _MIN_SAMPLES tune the gates
        without a rebuild; each falls back to the conservative default above.
        """
        return cls(
            enabled=enabled,
            rtf_target=_env_float("SUNOFLOW_STT_RTF_TARGET", DEFAULT_RTF_TARGET),
            min_agreement=_env_float("SUNOFLOW_STT_MIN_AGREEMENT", DEFAULT_MIN_AGREEMENT),
            min_samples=_env_int("SUNOFLOW_STT_MIN_SAMPLES", DEFAULT_MIN_SAMPLES),
            state_path=state_path,
            clock=clock,
        )

    def route(self, *, consent: bool, model_loaded: bool) -> str:
        """The routing decision for a dictation happening right now.

        ``consent`` is the user's per-install choice to allow cloud STT;
        ``model_loaded`` is whether the local model is resident and usable.
        """
        with self._lock:
            return self._route_locked(consent=consent, model_loaded=model_loaded)

    def _route_locked(self, *, consent: bool, model_loaded: bool) -> str:
        """Routing decision assuming the caller already holds ``self._lock``.

        Split out so ``snapshot`` can report the live route without re-entering
        the (non-reentrant) lock it already holds.
        """
        if self._cut_over:
            # Once trusted, local is the whole story — even if the model is
            # momentarily not loaded (a reload), routing local yields today's
            # soft-empty rather than silently reopening the cloud path.
            return ROUTE_LOCAL
        can_cloud = self._enabled and consent
        if model_loaded:
            # Local is available. Validate it against the cloud when we still
            # can; otherwise it is simply the answer.
            return ROUTE_SHADOW if can_cloud else ROUTE_LOCAL
        # No local model yet.
        return ROUTE_CLOUD if can_cloud else ROUTE_WAIT

    def record_shadow(self, *, rtf: float, agreement: float) -> bool:
        """Record one local-vs-cloud comparison. Returns True iff it cut over.

        A comparison is one shadow dictation: local ran on the same audio the
        cloud transcribed, ``rtf`` is how fast local was, ``agreement`` is how
        close local came to the cloud transcript.
        """
        with self._lock:
            if self._cut_over:
                return False
            self._samples.append(
                {"rtf": float(rtf), "agreement": float(agreement), "at": self._clock()}
            )
            if self._decide_cutover_locked():
                self._cut_over = True
                self._cutover_at = self._clock()
                self._save_state_locked()
                return True
            return False

    def force_local(self) -> None:
        """Cut over immediately, skipping validation.

        For a user who explicitly chooses on-device only, or an operator override
        — the app can flip the switch without waiting for the shadow phase.
        """
        with self._lock:
            if not self._cut_over:
                self._cut_over = True
                self._cutover_at = self._clock()
                self._save_state_locked()

    def _decide_cutover_locked(self) -> bool:
        if len(self._samples) < self._min_samples:
            return False
        recent = list(self._samples)[-self._min_samples:]
        med_rtf = _median([s["rtf"] for s in recent])
        med_ag = _median([s["agreement"] for s in recent])
        # Median, not mean: one slow first inference (kernel compile) or one
        # noisy clip should not veto an otherwise-ready model, nor should one
        # lucky sample carry an unready one over the line.
        return med_rtf <= self._rtf_target and med_ag >= self._min_agreement

    @property
    def cut_over(self) -> bool:
        with self._lock:
            return self._cut_over

    def snapshot(self, *, consent: bool = True, model_loaded: bool = True) -> dict:
        """State for GET /model/status, so the app can show a warm-start banner.

        ``consent``/``model_loaded`` let it report the live route; pass the same
        values the request path uses.
        """
        with self._lock:
            recent = list(self._samples)[-self._min_samples:]
            return {
                "stt_mode": self._route_locked(consent=consent, model_loaded=model_loaded),
                "cut_over": self._cut_over,
                "enabled": self._enabled,
                "samples": len(self._samples),
                "median_rtf": _median([s["rtf"] for s in recent]) if recent else None,
                "median_agreement": _median([s["agreement"] for s in recent]) if recent else None,
                "rtf_target": self._rtf_target,
                "min_agreement": self._min_agreement,
                "min_samples": self._min_samples,
            }

    # --- persistence -----------------------------------------------------------
    # The cutover verdict survives a sidecar restart so a machine that already
    # migrated to local does not re-open the cloud path (and re-spend the meter)
    # on the next launch. Only the verdict is persisted — the samples are
    # in-flight working state. All failures are swallowed: a missing or corrupt
    # state file just means "not cut over yet", which is safe (it re-validates).

    def _load_state(self) -> None:
        if not self._state_path:
            return
        try:
            with open(self._state_path) as f:
                data = json.load(f)
            if isinstance(data, dict) and data.get("cut_over"):
                self._cut_over = True
                self._cutover_at = data.get("cutover_at")
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return

    def _save_state_locked(self) -> None:
        if not self._state_path:
            return
        try:
            os.makedirs(os.path.dirname(self._state_path), exist_ok=True)
            tmp = self._state_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"cut_over": self._cut_over, "cutover_at": self._cutover_at}, f)
            os.replace(tmp, self._state_path)
        except OSError:
            return


def _env_float(key: str, default: float) -> float:
    v = os.environ.get(key)
    if not v:
        return default
    try:
        return float(v)
    except ValueError:
        return default


def _env_int(key: str, default: int) -> int:
    v = os.environ.get(key)
    if not v:
        return default
    try:
        return int(v)
    except ValueError:
        return default
