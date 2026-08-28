"""A stub cleanup gateway, shared by the tests for both sidecar copies.

The macOS sidecar is still the single-file ``sidecar/server.py`` and carries its
own copy of the gateway logic; the shared tree has ``sidecars/shared/cleanup.py``.
Drift between those two is what shipped a Windows build with no entitlement
checking, so the scenarios are written once here and run against both.
"""
import base64
import http.server
import json
import threading
import time

import urllib3


class _Server(http.server.ThreadingHTTPServer):
    """Threaded on purpose.

    A plain HTTPServer handles one connection at a time, and with HTTP/1.1
    keep-alive it sits inside a live connection waiting for the next request —
    so ``shutdown()`` blocks and the suite hangs. Threading it removes the
    constraint entirely.
    """

    daemon_threads = True
    allow_reuse_address = True


class Stub(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    reply = {"code": 200, "body": b"{}", "ctype": "application/json"}
    # The last request body seen, decoded. Kept so a test can assert what the
    # sidecar actually put on the wire — which is the only way to catch a field
    # that is built correctly and then never sent.
    last_request = None

    def _send(self):
        # Drain the request body before replying. Answering without reading it
        # resets the connection, which the code under test correctly reads as an
        # outage — so an un-drained stub silently exercises the wrong branch.
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            type(self).last_request = json.loads(raw) if raw else None
        except ValueError:
            type(self).last_request = None
        body = type(self).reply["body"]
        self.send_response(type(self).reply["code"])
        self.send_header("Content-Type", type(self).reply["ctype"])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = _send

    def log_message(self, *args):
        pass


class Gateway:
    """Controls what the stub answers, and can make it vanish entirely."""

    def __init__(self, cleanup_mod, lease_mod, monkeypatch, port):
        self._cleanup = cleanup_mod
        self.lease = lease_mod
        self._monkeypatch = monkeypatch
        self._port = port
        self.replies(200, {"cleaned": "Hello world."})

    def last_request(self):
        """The body of the most recent request the sidecar sent."""
        return Stub.last_request

    def replies(self, code, body, ctype="application/json"):
        Stub.last_request = None
        Stub.reply = {
            "code": code,
            "body": body if isinstance(body, bytes) else json.dumps(body).encode(),
            "ctype": ctype,
        }

    def unreachable(self):
        """Nothing listening — the /etc/hosts bypass, in one call."""
        self._monkeypatch.setattr(self._cleanup, "CLEANUP_URL", "http://127.0.0.1:1/cleanup")
        self._monkeypatch.setattr(self._cleanup, "ENTITLEMENT_URL", "http://127.0.0.1:1/entitlement")

    def issue_lease(self, key, ttl=None, uid="u1"):
        """A lease exactly as the real gateway would sign one."""
        ttl = self.lease.LEASE_TTL_SECONDS if ttl is None else ttl
        payload = json.dumps({
            "kid": self.lease.fingerprint(key), "uid": uid,
            "iat": int(time.time()), "exp": int(time.time() + ttl),
        }).encode()
        encoded = base64.urlsafe_b64encode(payload).decode().rstrip("=")
        return encoded + "." + self.lease._sign(encoded)

    def bank_lease(self, key, ttl=None):
        """Put a lease on disk, bypassing save() so expired ones can be staged."""
        with open(self.lease.LEASE_PATH, "w", encoding="utf-8") as f:
            json.dump({"lease": self.issue_lease(key, ttl)}, f)


SECRET = "test-gateway-secret"


def serve(cleanup_mod, lease_mod, monkeypatch, tmp_path):
    """Start the stub and point a sidecar's cleanup module at it.

    Yields a :class:`Gateway`; the caller is a pytest fixture that shuts the
    server down afterwards.
    """
    server = _Server(("127.0.0.1", 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]

    monkeypatch.setattr(cleanup_mod, "CLEANUP_URL", f"http://127.0.0.1:{port}/cleanup")
    monkeypatch.setattr(cleanup_mod, "ENTITLEMENT_URL", f"http://127.0.0.1:{port}/entitlement")
    monkeypatch.setattr(cleanup_mod, "CLEANUP_KEY", "")
    monkeypatch.setattr(lease_mod, "LEASE_SECRET", SECRET)
    monkeypatch.setattr(lease_mod, "LEASE_PATH", str(tmp_path / "lease.json"))

    return server, Gateway(cleanup_mod, lease_mod, monkeypatch, port)


class Connections:
    """How many fresh TCP connections the sidecar has opened."""

    count = 0


def count_connections(monkeypatch):
    """Start counting the sockets the sidecar dials, until the test ends.

    Connection reuse is invisible in the response body, so counting sockets is
    the only way to catch a slide back to ``requests.post``/``requests.get``.
    Those build a throwaway Session per call, which puts a DNS lookup and a TCP
    and TLS handshake — ~0.4s — between the user's last word and their pasted
    text, on every single dictation.
    """
    counter = Connections()
    original = urllib3.connection.HTTPConnection.connect

    def counted(self, *args, **kwargs):
        counter.count += 1
        return original(self, *args, **kwargs)

    monkeypatch.setattr(urllib3.connection.HTTPConnection, "connect", counted)
    return counter


def verdicts(cleanup_mod, key):
    """Run one scenario through cleanup-on and cleanup-off.

    Both paths must agree: switching cleanup off is a quality setting, never a
    way to skip the only entitlement check in the product.
    """
    out = {}
    clean = cleanup_mod.clean_with_gateway
    for name, call in (
        ("cleanup_on", lambda: clean("hello world", key=key)),
        ("cleanup_off", lambda: cleanup_mod.check_entitlement(key)),
    ):
        try:
            call()
            out[name] = "served"
        except cleanup_mod.NotEntitled as exc:
            out[name] = f"blocked:{exc.code}"
    return out
