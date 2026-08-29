#!/usr/bin/env python3
"""End-to-end dictation smoke test: does the shipped bundle turn speech into words?

The freeze job already proves the bundle boots, answers /health and can import
its STT stack. None of that touches the model. The adapter's own load-time pass
(``_verify_runnable``) goes one step further and runs a real forward pass, but on
a 220 Hz tone — it proves inference *completes*, and is deliberately indifferent
to what comes out. A decoder wired to the wrong vocab, an int8 export whose
quantised graph produces mush, an onnx-asr upgrade that changed how the
preprocessor is resolved: all of those load cleanly, pass the tone, and then
answer every real dictation with garbage or an empty string.

So this drives the frozen exe the way the tray app does — model download over
HTTP, then a multipart POST /transcribe of a real spoken clip — and asserts on
the transcript.

It runs on a GitHub runner because the int8 variant *is* the CPU path: it is
pinned to CPUExecutionProvider in ``adapter._select_providers`` and never goes
near DirectML. That is also this test's boundary. It exercises the engine every
GPU-less user runs, and says nothing whatsoever about DirectML, which still
needs ``validate_onnx.py`` on real hardware.

Two things are faked, both deliberately:

  * **The cleanup gateway.** A stub stands in for it, because /transcribe checks
    entitlement even with cleanup off (shared/app.py) — by design, so switching
    cleanup off is not a free-dictation switch. The stub echoes the transcript
    back, and we assert on what it *received*, which is how the cleanup round
    trip gets checked without depending on an LLM's output.
  * **Nothing else.** The model, the engine, the download manager and the HTTP
    layer are the real ones, inside the real bundle.

Stdlib only, so it runs under the bare runner Python with nothing installed.

    python sidecars/windows/dictation_smoke.py \
        --exe sidecars/windows/dist/SunoFlowSidecar/SunoFlowSidecar.exe \
        --wav sidecars/testdata/dictation-smoke.wav \
        --model-dir D:/sunoflow-model
"""
import argparse
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path

_REPO_ROOT = str(Path(__file__).resolve().parents[2])
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

# The content words the fixture clip must yield. A set-containment check, not an
# equality check: casing, punctuation and the odd filler are the STT engine's
# business, and pinning them would turn every harmless upstream improvement into
# a red build. What must not change is that these words come out at all.
DEFAULT_EXPECT = "quick,brown,fox,jumps,lazy,dog,river"

DEVICE_KEY = "ci-dictation-smoke"


# --- the stand-in gateway ------------------------------------------------------

class _Gateway(http.server.BaseHTTPRequestHandler):
    """Answers /entitlement and /cleanup exactly well enough to let a dictation through.

    Kept separate from ``shared/tests/gateway_stub.py`` on purpose: that one
    drives the sidecar in-process through monkeypatch, which cannot reach inside
    a frozen exe. This one is a real socket the exe is pointed at with
    SUNOFLOW_CLEANUP_URL.
    """

    protocol_version = "HTTP/1.1"
    seen = []          # every /cleanup body received, in order
    lock = threading.Lock()

    def _reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        # A 2xx with no lease. save() verifies before writing and drops an
        # unsigned token, which is what we want: the run then depends on the
        # stub actually being reachable rather than on a lease papering over it.
        self._reply(200, {})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        with _Gateway.lock:
            _Gateway.seen.append(body)
        # Echo the transcript straight back as the "cleaned" text. The real
        # gateway would rewrite it; a smoke test that depended on how an LLM
        # chose to rewrite it would be testing the LLM.
        text = (body or {}).get("text", "")
        self._reply(200, {"cleaned": text})

    def log_message(self, *args):
        pass


class _Threaded(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# --- HTTP helpers (stdlib; the runner Python has no requests) -------------------

def _get_json(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read())


def _post_json(url, timeout=30):
    req = urllib.request.Request(url, data=b"", method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def _post_transcribe(url, wav_path, timeout=300):
    """Multipart POST of the clip, shaped like the one the tray app sends."""
    boundary = f"----sunoflow{uuid.uuid4().hex}"
    with open(wav_path, "rb") as f:
        audio = f.read()

    def part(header, payload):
        return (f"--{boundary}\r\n{header}\r\n\r\n".encode() + payload + b"\r\n")

    body = (
        part(
            'Content-Disposition: form-data; name="file"; filename="clip.wav"\r\n'
            "Content-Type: audio/wav",
            audio,
        )
        # Sent rather than omitted so the multipart shape matches a real
        # dictation's — a File-plus-Form request, not a File-only one.
        + part('Content-Disposition: form-data; name="context"', b"CI smoke test")
        + part('Content-Disposition: form-data; name="screen"', b"")
        + f"--{boundary}--\r\n".encode()
    )
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
            "X-SunoFlow-Device-Key": DEVICE_KEY,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as exc:
        # 402 lands here. Its body carries the gateway's own wording, which is
        # the whole diagnosis, so read it rather than just reporting the status.
        return exc.code, json.loads(exc.read() or b"{}")


# --- the run -------------------------------------------------------------------

def _require_port_free(port, grace=10):
    """Refuse to start if something still owns the port after ``grace`` seconds.

    Not a theoretical tidiness check. A sidecar left over from an earlier step
    (or, on a dev box, the one the user has running) answers /health perfectly,
    and every assertion below then silently interrogates *that* process instead
    of the bundle under test — reporting a pass, or a baffling 402 from the real
    gateway, with nothing in the output pointing at the mix-up.

    The grace period is for the handoff from the workflow's own boot-and-health
    step, which kills its sidecar immediately before this one runs. A forced
    kill frees the listener at once, so this normally returns on the first try;
    the retries exist so that a slow release is a short wait rather than a red
    build.
    """
    deadline = time.monotonic() + grace
    while True:
        with socket.socket() as sock:
            sock.settimeout(2)
            if sock.connect_ex(("127.0.0.1", port)) != 0:
                return
        if time.monotonic() >= deadline:
            raise SystemExit(
                f"[boot] port {port} is still serving something after {grace}s. "
                f"This test would have talked to it instead of the bundle under "
                f"test — stop it, or pass --port."
            )
        time.sleep(1)


def _wait_for_health(base, deadline, proc):
    """Poll /health until it answers, the process dies, or we run out of time.

    Watching ``proc`` matters: a bundle that exits on startup would otherwise
    burn the whole timeout before reporting a silence its own log already
    explained.
    """
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise SystemExit(
                f"[boot] the sidecar exited with code {proc.returncode} before "
                f"serving /health — see the log below."
            )
        try:
            return _get_json(f"{base}/health", timeout=3)
        except Exception:
            time.sleep(2)
    return None


def _ensure_model(base, deadline):
    """Download the model if it isn't on disk, then wait for it to load.

    Returns the last /model/status seen. Both halves matter: a cache hit still
    has to wait, because the exe loads at startup and a cold int8 load is not
    instant on a runner's CPU.
    """
    status = _get_json(f"{base}/model/status", timeout=10)
    if not status["model_present"]:
        print(f"[model] not on disk — starting download into {status['model_dir']}")
        print(f"[model] variant={status.get('variant')} "
              f"({status.get('variant_reason')})")
        _post_json(f"{base}/model/download")
    else:
        print(f"[model] already on disk (cache hit) in {status['model_dir']}")

    last_line = ""
    while time.monotonic() < deadline:
        status = _get_json(f"{base}/model/status", timeout=10)
        if status["model_loaded"]:
            return status
        if status.get("error"):
            raise SystemExit(f"[model] FAILED — {status['error']}")
        if status.get("load_error"):
            raise SystemExit(f"[model] FAILED to load — {status['load_error']}")
        # A heartbeat, not a progress bar: a silent step is indistinguishable
        # from a hung one in a CI log, and this step can legitimately run for
        # minutes on a cold cache.
        done, total = status.get("overall_done", 0), status.get("overall_total", 0)
        line = (f"[model] phase={status.get('phase')} file={status.get('current_file')} "
                f"({done}/{total})")
        if line != last_line:
            print(line, flush=True)
            last_line = line
        time.sleep(5)
    raise SystemExit("[model] timed out waiting for the model to load")


def _normalize(text):
    return {
        "".join(ch for ch in word if ch.isalnum())
        for word in text.lower().split()
    } - {""}


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--exe", required=True, help="Path to the frozen SunoFlowSidecar.exe")
    p.add_argument("--wav", required=True, help="Speech clip to transcribe")
    p.add_argument("--model-dir", required=True, help="SUNOFLOW_MODEL_DIR for this run")
    p.add_argument("--variant", default="int8",
                   help="Pinned SUNOFLOW_MODEL_VARIANT (default: int8, the CPU path)")
    p.add_argument("--expect", default=DEFAULT_EXPECT,
                   help="Comma-separated words the transcript must contain")
    # The frozen bundle hardcodes 8765 (freeze_entry.main), so this does not
    # move the sidecar — it moves where we look for it, which is only useful
    # when --exe points at a stand-in that honours a different port.
    p.add_argument("--port", type=int, default=8765,
                   help="Port the sidecar serves on (the frozen bundle: 8765)")
    p.add_argument("--timeout", type=int, default=1200,
                   help="Seconds for boot + download + load")
    p.add_argument("--log", default="dictation-smoke-sidecar.log")
    args = p.parse_args()

    expect = {w.strip().lower() for w in args.expect.split(",") if w.strip()}
    base = f"http://127.0.0.1:{args.port}"

    with wave.open(args.wav) as w:
        audio_seconds = w.getnframes() / float(w.getframerate())
    print(f"[input] {args.wav}  {audio_seconds:.2f} s")

    _require_port_free(args.port)

    gateway = _Threaded(("127.0.0.1", 0), _Gateway)
    threading.Thread(target=gateway.serve_forever, daemon=True).start()
    gw_port = gateway.server_address[1]
    print(f"[gateway] stub listening on 127.0.0.1:{gw_port}")

    env = dict(os.environ)
    env.update({
        # Pinned, not probed. The runner's virtual display adapter may or may
        # not publish a memory size, and if it reads >= 4 GB the probe would
        # commit this job to the 2.5 GB fp32 download and a DirectML load that
        # cannot bind. int8 is both the deterministic answer and the one worth
        # testing here.
        "SUNOFLOW_MODEL_VARIANT": args.variant,
        "SUNOFLOW_MODEL_DIR": os.path.abspath(args.model_dir),
        "SUNOFLOW_CLEANUP_URL": f"http://127.0.0.1:{gw_port}/cleanup",
        # Out of LOCALAPPDATA so a lease can never survive into another run and
        # let a broken entitlement path pass on a stale one.
        "SUNOFLOW_LEASE_PATH": os.path.abspath("dictation-smoke-lease.json"),
        "SUNOFLOW_VERSION": "ci-smoke",
    })

    log = open(args.log, "wb")
    # Absolute, so the bundle is found regardless of where this was invoked from.
    proc = subprocess.Popen(
        [os.path.abspath(args.exe)], env=env, stdout=log, stderr=subprocess.STDOUT,
    )
    deadline = time.monotonic() + args.timeout
    failure = None
    try:
        health = _wait_for_health(
            base, min(deadline, time.monotonic() + 120), proc,
        )
        if not health:
            raise SystemExit("[boot] the sidecar never answered /health")
        print(f"[boot] /health -> {health}")

        status = _ensure_model(base, deadline)
        print(f"[model] loaded — variant={status.get('variant')} "
              f"runtime={status.get('runtime')}")

        started = time.perf_counter()
        code, body = _post_transcribe(f"{base}/transcribe", args.wav)
        elapsed = time.perf_counter() - started

        if code != 200:
            raise SystemExit(f"[transcribe] HTTP {code} — {body}")

        raw = (body.get("raw") or "").strip()
        cleaned = (body.get("cleaned") or "").strip()
        rtf = audio_seconds / elapsed if elapsed > 0 else 0.0
        print(f"\n[transcribe] {elapsed*1000:.0f} ms  RTF={rtf:.2f}x realtime")
        print(f"[transcribe] raw     = {raw!r}")
        print(f"[transcribe] cleaned = {cleaned!r}")

        if not raw:
            # The shared app soft-fails inference to an empty transcript so one
            # bad clip can never break dictation. Past the model_loaded check
            # above, that soft failure is the bug rather than a kindness.
            raise SystemExit(
                "[transcribe] FAILED — empty transcript from a loaded model. "
                "Inference ran and produced nothing; see the sidecar log below."
            )

        missing = sorted(expect - _normalize(raw))
        if missing:
            raise SystemExit(
                f"[transcribe] FAILED — transcript is missing {missing}. "
                f"The engine ran and produced words, but not the spoken ones: "
                f"suspect the vocab, the decoder, or the quantised export."
            )
        print(f"[transcribe] OK — all {len(expect)} expected words present")

        # The cleanup round trip, asserted on what the gateway received rather
        # than on what it returned. Proves the sidecar reached it with the real
        # transcript, without making the test depend on an LLM's rewording.
        with _Gateway.lock:
            seen = list(_Gateway.seen)
        if not seen:
            raise SystemExit(
                "[gateway] FAILED — the sidecar never called /cleanup. "
                "Entitlement would not have been checked for this dictation."
            )
        if (seen[-1] or {}).get("text", "").strip() != raw:
            raise SystemExit(
                f"[gateway] FAILED — /cleanup received "
                f"{(seen[-1] or {}).get('text')!r}, not the transcript {raw!r}"
            )
        print("[gateway] OK — /cleanup received the transcript verbatim")

        print(f"\nDictation smoke passed on {status.get('runtime')} "
              f"({status.get('variant')}), {rtf:.2f}x realtime.")
    except SystemExit as exc:
        failure = str(exc)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
        gateway.shutdown()
        log.close()
        print("\n--- sidecar log ---")
        try:
            print(Path(args.log).read_text(errors="replace"))
        except OSError:
            print("(no log)")

    if failure:
        print(failure, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
