"""Hosted cleanup-gateway POST.

Cleanup/LLM does not run locally. The sidecar POSTs the transcript to a remote
cleanup gateway (Go service, see cleanup-gateway/) which owns the cleanup
instruction, the LLM backend (Ollama/OpenAI/Claude), and the echo-retry guard.
So the live path is a single POST that soft-fails to raw text on ANY error —
identical fallback behaviour to the old local-Ollama path. Override
SUNOFLOW_CLEANUP_URL / SUNOFLOW_CLEANUP_KEY for dev (e.g. point at a local
docker-compose stack).
"""
import os

import requests

CLEANUP_URL = os.environ.get("SUNOFLOW_CLEANUP_URL", "https://cleanup.mirrorli.art/cleanup")
CLEANUP_KEY = os.environ.get("SUNOFLOW_CLEANUP_KEY", "FQ2xxpibf5RBIeEzouwSXxU0Nn2sz-nI2H1STykqr1A")


def clean_with_gateway(text: str, context: str = "", recent: list = None, screen: str = "") -> str:
    """Clean a transcript via the hosted cleanup gateway.

    On ANY error (network, auth, timeout, non-200) fall back to the raw text so
    dictation never fails because cleanup is down. Matches the old local-Ollama
    soft-fail behaviour byte for byte.
    """
    if not text.strip():
        return text
    recent = recent or []
    context = (context or "").strip()
    screen = (screen or "").strip()

    try:
        resp = requests.post(
            CLEANUP_URL,
            headers={"Authorization": f"Bearer {CLEANUP_KEY}"},
            json={"text": text, "context": context, "recent": recent, "screen": screen},
            timeout=60,
        )
        resp.raise_for_status()
        cleaned = (resp.json().get("cleaned") or "").strip()
        # Gateway already applies echo-retry, but guard against an empty payload
        # falling through — return raw rather than an empty string.
        return cleaned or text
    except Exception as exc:
        print(f"Cleanup gateway failed, falling back to raw text: {exc}")
        return text