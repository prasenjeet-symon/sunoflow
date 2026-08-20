"""SunoFlow sidecar shared core.

Platform-agnostic logic shared by every sidecar implementation (macOS
parakeet-mlx, Windows onnxruntime-directml): the corrections dictionary,
recent-history continuity, the hosted cleanup-gateway POST, the WAV duration
guard, and the FastAPI app factory + all HTTP routes.

Each platform implements `sidecars.shared.app.SttAdapter` and calls
`create_app(adapter=..., corrections_path=...)`. See `docs/CONTRACT.md` for the
HTTP contract both sidecars MUST obey.
"""