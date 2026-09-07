"""Tests for the shared audio helpers — the Opus compression of the cloud upload.

Run with ``pytest sidecars/shared/tests``. The encode test is skipped where
ffmpeg is not installed (e.g. a Windows checkout), matching the runtime fallback.
"""
import os
import shutil
import struct
import sys
import wave

import pytest

# Make ``sidecars.*`` importable when run from the repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__)))))

from sidecars.shared import audio  # noqa: E402


def _write_wav(path, seconds=1.0, rate=16000):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<h", 0) * int(rate * seconds))


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_encode_opus_shrinks_the_upload(tmp_path):
    wav = str(tmp_path / "clip.wav")
    _write_wav(wav)
    out = audio.encode_opus(wav)
    assert out, "expected Opus bytes"
    # Opus of a 16 kHz PCM clip is dramatically smaller than the WAV.
    assert len(out) < os.path.getsize(wav)
    # Ogg stream magic — proves it's really an Ogg/Opus container, not the WAV.
    assert out[:4] == b"OggS"


def test_encode_opus_returns_none_when_disabled(tmp_path, monkeypatch):
    wav = str(tmp_path / "clip.wav")
    _write_wav(wav)
    monkeypatch.setattr(audio, "_STT_COMPRESS", False)
    assert audio.encode_opus(wav) is None  # caller falls back to raw WAV


def test_encode_opus_returns_none_when_ffmpeg_missing(tmp_path, monkeypatch):
    wav = str(tmp_path / "clip.wav")
    _write_wav(wav)
    monkeypatch.setattr(audio, "_STT_COMPRESS", True)
    monkeypatch.setattr(audio.shutil, "which", lambda _name: None)
    assert audio.encode_opus(wav) is None


def test_ensure_ffmpeg_on_path_honors_override(tmp_path, monkeypatch):
    exe = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"
    (tmp_path / exe).write_text("")  # stand-in for a bundled binary
    monkeypatch.setenv("SUNOFLOW_FFMPEG", str(tmp_path))
    monkeypatch.setenv("PATH", os.path.join(os.sep, "usr", "bin"))
    got = audio.ensure_ffmpeg_on_path()
    assert got == str(tmp_path / exe)
    # the bundle dir must now win PATH resolution
    assert os.environ["PATH"].split(os.pathsep)[0] == str(tmp_path)


def test_ensure_ffmpeg_on_path_none_when_absent(monkeypatch):
    monkeypatch.delenv("SUNOFLOW_FFMPEG", raising=False)
    vendor = os.path.join(os.path.dirname(audio.__file__), "vendor", "ffmpeg")
    if os.path.exists(vendor):
        pytest.skip("a vendored ffmpeg is present in this checkout")
    assert audio.ensure_ffmpeg_on_path() == ""
