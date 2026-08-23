# SunoFlow cleanup gateway

A single static Go binary that authenticates clients, rate-limits per account, and
proxies cleanup requests to the Gemini API. It is the sole holder of the
provider API key — no client ever sees it, which is the whole reason cleanup is
server-side. See `docs/CLEANUP_GATEWAY_ARCHITECTURE.md` for the full design.

## One-command stack (Docker Compose)

```sh
cd cleanup-gateway
cp .env.example .env          # then set ADMIN_TOKEN and GEMINI_API_KEY
docker compose up -d --build
```

That brings up two services on a private bridge network:

| service   | role                                      | exposed port     |
|-----------|-------------------------------------------|------------------|
| `gateway` | the Go binary (auth, rate-limit, cleanup) | 8080 (internal)  |
| `nginx`   | edge proxy + rate limit                   | `127.0.0.1:8081` |

Only nginx publishes a host port, and only on loopback — nothing here is
internet-facing directly. The gateway needs no inbound access and no local
model runtime; outbound HTTPS to Gemini is its only external dependency.

### Point it at the Cloudflare tunnel

The existing `kavachqr-dev` named tunnel (zone `mirrorli.art`) already has an
ingress for this service:

```
https://cleanup.mirrorli.art  ->  http://localhost:8081  (nginx)  ->  gateway:8080
```

That ingress and DNS route are already configured, so once `docker compose up
-d` is running, the public URL works immediately:

```sh
curl https://cleanup.mirrorli.art/health      # → {"status":"ok"}
curl https://cleanup.mirrorli.art/ready       # → {"backend":"gemini","backend_ok":true,...}
```

TLS is terminated by Cloudflare; nginx inside the compose stack is HTTP-only.

### First run

There is no model to pull and no warm-up. The gateway refuses to start without
`GEMINI_API_KEY`, so if the container is up, the backend is configured:

```sh
docker compose logs -f gateway
```

`/ready` reports `backend_ok: true` once Gemini answers a probe. If it stays
`false`, the key or outbound HTTPS is the problem — `/cleanup` keeps serving,
but falls back to returning the raw text uncleaned.

## Configure

All config is env-driven (12-factor). Edit `.env` and restart with
`docker compose up -d`. Defaults (from `.env.example`):

```sh
ADMIN_TOKEN=<long random secret>      # REQUIRED. Guards /admin/*.
GEMINI_API_KEY=<AI Studio key>        # REQUIRED. Startup fails without it.
GEMINI_MODEL=gemini-3.5-flash-lite    # server-controlled; change without a client release
GEMINI_THINKING_LEVEL=low             # minimal|low|medium|high
DEFAULT_QUOTA_RPM=60
DEFAULT_QUOTA_DAILY=5000
LOG_LEVEL=info                         # debug|info|warn|error
```

Both quotas are **per account**, not per device: a customer who pairs three
machines gets one allowance, not three. Usage is attributed to the account uid
where the gateway knows it (any paired device) and to the key id otherwise (a
legacy key, which belongs to no account).


Swap the model by editing `GEMINI_MODEL` in `.env`, then `docker compose up -d`.
No client release needed.

## Issue a key (manual, v1)

```sh
curl -X POST https://cleanup.mirrorli.art/admin/keys \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"label":"Prasenjeet MBP"}'
# → {"id":"...","key":"<plaintext-shown-once>","label":"...","created_at":...}
```

Hand the `key` to the user out-of-band. It is shown **once**; only the SHA-256
hash is stored. List keys (metadata only):

```sh
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://cleanup.mirrorli.art/admin/keys
```

Revoke:

```sh
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://cleanup.mirrorli.art/admin/keys/<id>
```

## Verify

```sh
# Liveness
curl https://cleanup.mirrorli.art/health
# Readiness (probes Gemini)
curl https://cleanup.mirrorli.art/ready
# Cleanup
curl -X POST https://cleanup.mirrorli.art/cleanup \
  -H "Authorization: Bearer <user-key>" \
  -H "Content-Type: application/json" \
  -d '{"text":"um so I think we should um ship this on friday"}'
# → {"cleaned":"So I think we should ship this on Friday."}
```

You can run the same calls against the local nginx port to bypass the tunnel:

```sh
curl http://127.0.0.1:8081/health
```

## Operational notes

- **Logs** are JSON on stdout: `docker compose logs -f gateway`. They contain
  metadata only (request id, key id, latency, status) — never transcript
  contents.
- **Swap the model** by editing `GEMINI_MODEL` in `.env` and re-running
  `docker compose up -d`. No client release needed.
- **Adding a backend** means implementing `backend.Backend` and adding a case in
  `cmd/gateway/main.go`; `BACKEND` then selects it. The cleanup handler and the
  prompt are provider-agnostic and stay unchanged.
- **Scaling:** v1 is single-host + SQLite (a docker volume). When a second
  host is needed, move the key store to Postgres and the rate limiter to Redis;
  the interfaces are designed so this is a storage swap, not a rewrite.
- **Admin IP allowlist:** uncomment the `allow`/`deny` block in
  `deploy/nginx.conf` and set your IP to restrict `/admin/*` at the edge as
  well as by token.

## Bare-metal / systemd alternative

The docker-compose stack is the recommended path. If you prefer to run the
binary directly on a host, the previous systemd + bare-nginx runbook still
applies — see `deploy/gateway.service` and set `DB_PATH` to a writable path.
The `deploy/nginx.conf` here is tuned for the docker context (HTTP-only); for
a bare-metal deployment with direct TLS, use certbot as before.