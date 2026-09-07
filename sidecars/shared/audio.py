"""Audio helpers shared by every sidecar."""

import os
import shutil
import subprocess
import sys


def ensure_ffmpeg_on_path() -> str:
    """Make a bundled ffmpeg discoverable, so the app carries no system dependency.

    ffmpeg is needed by BOTH the local STT engine (parakeet-mlx shells out to it
    to decode audio) and by encode_opus below. A shipped app can't rely on the
    user having Homebrew's ffmpeg, and a GUI-launched process gets a minimal PATH
    anyway — so we bundle a static ffmpeg and point the process at it here.

    Resolution order for the directory that holds the ffmpeg binary:
      1. $SUNOFLOW_FFMPEG — an explicit path to the binary or its directory.
      2. The frozen bundle (PyInstaller: sys._MEIPASS, else the executable's dir).
      3. A repo-local ``vendor/ffmpeg`` next to this module (dev bundling).
    The first hit is prepended to PATH so plain ``ffmpeg`` resolves to it for
    every consumer; when nothing is bundled, PATH is left untouched and the
    system ffmpeg (dev/brew) is used. Returns the resolved binary path, or "".
    """
    exe = "ffmpeg.exe" if os.name == "nt" else "ffmpeg"

    def _hit(d):
        return d if d and os.path.exists(os.path.join(d, exe)) else None

    dirs = []
    override = os.environ.get("SUNOFLOW_FFMPEG", "").strip()
    if override:
        dirs.append(override if os.path.isdir(override) else os.path.dirname(override))
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", None) or os.path.dirname(sys.executable)
        dirs += [base, os.path.join(base, "ffmpeg")]
    dirs.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor", "ffmpeg"))

    for d in dirs:
        found = _hit(d)
        if found:
            os.environ["PATH"] = found + os.pathsep + os.environ.get("PATH", "")
            return os.path.join(found, exe)
    return ""


# Resolve a bundled ffmpeg onto PATH at import, before anything shells out to it.
ensure_ffmpeg_on_path()

# Clips shorter than this can't hold real speech and make STT engines underflow
# (parakeet-mlx empirically crashes below ~0.01s as the mel length goes negative;
# 0.1s is a safe "too short to be speech" cutoff with margin). Below it we skip the
# model and return an empty transcript — see docs/CONTRACT.md §transcribe.
MIN_AUDIO_SECONDS = 0.1


def wav_duration_seconds(path: str):
    """Duration of a PCM WAV in seconds, or None if it can't be read."""
    import wave

    try:
        with wave.open(path, "rb") as w:
            rate = w.getframerate()
            if not rate:
                return None
            return w.getnframes() / float(rate)
    except Exception:
        return None


# Compress the cloud upload to Ogg/Opus by default. Off (raw WAV) when set to
# 0/false — e.g. if the gateway is pointed at OpenRouter, whose chat audio input
# accepts only wav/mp3, not Opus.
_STT_COMPRESS = os.environ.get("SUNOFLOW_STT_COMPRESS", "1").strip().lower() not in ("0", "false", "no", "")


def encode_opus(wav_path: str):
    """Encode a WAV file to Ogg/Opus (24 kbps mono) to shrink the cloud upload
    (~10x smaller than 16 kHz PCM), which speeds the sidecar→gateway→provider
    legs. Returns Opus bytes, or None to fall back to raw WAV when compression is
    disabled, ffmpeg/libopus is unavailable (e.g. the Windows build), or encoding
    fails. Groq's Whisper accepts Ogg/Opus; see _STT_COMPRESS for OpenRouter.
    """
    if not _STT_COMPRESS:
        return None
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    try:
        p = subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-i", wav_path,
             "-ac", "1", "-c:a", "libopus", "-b:a", "24k", "-f", "ogg", "pipe:1"],
            capture_output=True, timeout=15,
        )
        if p.returncode == 0 and p.stdout:
            return p.stdout
    except Exception as exc:
        print(f"Opus encode failed, sending raw WAV: {exc}")
    return None