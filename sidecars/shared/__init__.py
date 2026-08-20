"""SunoFlow shared sidecar core (lazy re-exports from the submodules).

Submodules (``audio``, ``cleanup``) are importable directly with no heavy
deps. The FastAPI-based ``app`` module is only imported on first attribute
access so that lightweight tools (e.g. ``validate_onnx.py``) can import
``sidecars.shared.audio`` without pulling in the web stack.
"""

__all__ = [
    "SttAdapter",
    "create_app",
    "MIN_AUDIO_SECONDS",
    "wav_duration_seconds",
    "clean_with_gateway",
]


def __getattr__(name):
    if name == "SttAdapter":
        from sidecars.shared.app import SttAdapter
        return SttAdapter
    if name == "create_app":
        from sidecars.shared.app import create_app
        return create_app
    if name == "MIN_AUDIO_SECONDS":
        from sidecars.shared.audio import MIN_AUDIO_SECONDS
        return MIN_AUDIO_SECONDS
    if name == "wav_duration_seconds":
        from sidecars.shared.audio import wav_duration_seconds
        return wav_duration_seconds
    if name == "clean_with_gateway":
        from sidecars.shared.cleanup import clean_with_gateway
        return clean_with_gateway
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")