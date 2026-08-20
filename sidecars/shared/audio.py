"""Audio helpers shared by every sidecar."""

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