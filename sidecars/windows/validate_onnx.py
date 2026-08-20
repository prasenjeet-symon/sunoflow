#!/usr/bin/env python3
"""Validate the Parakeet ONNX export under ONNX Runtime on a Windows GPU box.

This is the go/no-go gate for the Windows track. It answers two questions
before we build any UI:

1. Does the ``onnx-asr`` + ``onnxruntime-directml`` path actually transcribe
   real speech correctly on this machine's GPU?
2. How does its latency compare to the macOS MLX path (the baseline we must
   match for an acceptable dictation feel)?

It does NOT go through the FastAPI sidecar — it loads the model directly so we
isolate STT-engine behaviour from the HTTP layer. Run it on the target Windows
box after installing the deps::

    pip install onnxruntime-directml onnx-asr[hub] soundfile numpy

    # With a local model dir (downloaded by the sidecar's /model/download, or
    # by onnx-asr itself on first run):
    python sidecars/windows/validate_onnx.py --model-dir <path-to-onnx-model>

    # Or let onnx-asr download from HF into its cache on first run:
    python sidecars/windows/validate_onnx.py --wav some-audio.wav

Pass ``--provider cpu`` to force the CPU EP for a baseline against the DirectML
GPU number (proves the GPU is actually being used and the speedup is real).
Prints: provider(s) actually used, transcript, and per-call wall time + RTF
(audio seconds / process seconds; higher is better, >1 means faster than
realtime).
"""
import argparse
import os
import sys
import time
from pathlib import Path

# Make ``sidecars.*`` importable when run from the repo.
_REPO_ROOT = str(Path(__file__).resolve().parents[2])
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from sidecars.shared.audio import wav_duration_seconds  # noqa: E402


def _select_providers(rt_module, requested):
    if requested:
        return requested
    available = list(rt_module.get_available_providers())
    if "DmlExecutionProvider" in available:
        return ["DmlExecutionProvider", "CPUExecutionProvider"]
    return ["CPUExecutionProvider"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--model-dir", default=None,
        help="Local ONNX model directory. If omitted, onnx-asr downloads "
             "nemo-parakeet-tdt-0.6b-v3 from HF into its cache on first run.",
    )
    parser.add_argument(
        "--model-id", default="nemo-parakeet-tdt-0.6b-v3",
        help="onnx-asr model name (default: nemo-parakeet-tdt-0.6b-v3).",
    )
    parser.add_argument(
        "--provider", action="append", default=None,
        help="Execution provider(s) to force (e.g. DmlExecutionProvider, "
             "CPUExecutionProvider). Repeatable. Defaults to DirectML if "
             "available, else CPU.",
    )
    parser.add_argument(
        "--wav", action="append", default=None,
        help="WAV file(s) to transcribe. Repeatable. If none given, generates a "
             "short synthetic tone as a smoke test (will not produce real text).",
    )
    parser.add_argument(
        "--runs", type=int, default=1,
        help="Number of timed runs per WAV (to amortize one-time graph setup).",
    )
    args = parser.parse_args()

    import onnx_asr
    import onnxruntime as rt

    providers = _select_providers(rt, args.provider)
    print(f"[setup] onnxruntime providers available: {rt.get_available_providers()}")
    print(f"[setup] loading model: id={args.model_id!r} path={args.model_dir!r} "
          f"providers={providers}")

    t0 = time.perf_counter()
    model = onnx_asr.load_model(
        args.model_id,
        path=args.model_dir,
        providers=providers,
    )
    load_s = time.perf_counter() - t0
    print(f"[setup] model loaded in {load_s:.2f} s")

    wavs = args.wav or []
    if not wavs:
        # Smoke test with a generated silent-ish WAV so the load path at least
        # runs end to end on a box with no test audio handy. Real validation
        # needs a real speech WAV — pass --wav.
        import tempfile
        import wave
        import struct
        fd, tmp = tempfile.mkstemp(suffix=".wav")
        with os.fdopen(fd, "wb") as w:
            with wave.open(w, "wb") as ww:
                ww.setnchannels(1)
                ww.setsampwidth(2)
                ww.setframerate(16000)
                # 1s of near-zero samples — won't transcribe to anything, but
                # exercises load + the preprocessor pipeline.
                ww.writeframes(struct.pack("<" + "h" * 16000, *([10] * 16000)))
        wavs = [tmp]

    for wav in wavs:
        duration = wav_duration_seconds(wav)
        print(f"\n[input] {wav}  duration={duration}s")
        for run in range(args.runs):
            t1 = time.perf_counter()
            text = model.recognize(wav)
            dt = time.perf_counter() - t1
            rtf = (dt / duration) if duration else float("inf")
            print(f"[run {run}] {dt*1000:.1f} ms  RTF={rtf:.3f}  "
                  f"({len(text)} chars)  text={text!r}")

    # Report the EP the session actually bound to.
    try:
        used = model._asr._encoder.get_providers()  # type: ignore[attr-defined]
        print(f"\n[provider] session actually used: {used}")
    except Exception:
        pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())