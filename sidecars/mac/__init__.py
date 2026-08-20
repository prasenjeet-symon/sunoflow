"""macOS sidecar — parakeet-mlx STT engine.

Implements ``sidecars.shared.app.SttAdapter`` over the parakeet-mlx runtime
(MLX/Metal, Apple-Silicon-only) and wires it into the shared FastAPI app.
"""