# SunoFlow cleanup gateway

A single static Go binary that authenticates clients, rate-limits per key, and
proxies cleanup requests to a local Ollama — the sole caller of Ollama, which
stays on a private docker network. See `docs/CLEANUP_GATEWAY_ARCHITECTURE.md`
for the full design.

## One-command local stack (Docker Compose)

```sh
cd cleanup-gateway
cp .env.example .env          # then edit ADMIN_TOKEN to a long random secret
docker compose up -d --build
```

That brings up four services on a private bridge network:

| service       | role                                           | exposed port        |
|---------------|------------------------------------------------|---------------------|
| `ollama`      | LLM backend (internal only)                    | — (none)            |
| `ollama-init` | one-shot model puller                          | — (exits 0)         |
| `gateway`     | the Go binary (auth, rate-limit, cleanup)      | 8080 (internal)     |
| `nginx`       | edge proxy + rate limit                        | `127.0.0.1:8081`    |

Only nginx publishes a host port, and only on loopback — nothing here is
internet-facing directly. Ollama is unreachable from the host.

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
curl https://cleanup.mirrorli.art/ready       # → {"backend":"ollama","backend_ok":true,...}
```

TLS is terminated by Cloudflare; nginx inside the compose stack is HTTP-only.

### First run

`ollama-init` waits for Ollama, then pulls `OLLAMA_MODEL` (default
`llama3.2:3b`, ~2 GB). Watch progress:

```sh
docker compose logs -f ollama-init
```

Once it prints `model ready`, `/ready` flips to `backend_ok: true` and `/cleanup`
returns cleaned text instead of the raw fallback.

## Configure

All config is env-driven (12-factor). Edit `.env` and restart with
`docker compose up -d`. Defaults (from `.env.example`):

```sh
ADMIN_TOKEN=<long random secret>      # REQUIRED. Guards /admin/*.
OLLAMA_MODEL=llama3.2:3b              # server-controlled; change without a client release
DEFAULT_QUOTA_RPM=60
DEFAULT_QUOTA_DAILY=5000
LOG_LEVEL=info                         # debug|info|warn|error
```

Swap the model by editing `OLLAMA_MODEL` in `.env`, then
`docker compose up -d && docker compose up -d ollama-init` (re-pulls the new
model). No client release needed.

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
# Readiness (checks Ollama)
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
- **Swap the model** by editing `OLLAMA_MODEL` in `.env` and re-running
  `docker compose up -d ollama-init`. No client release needed.
- **Backend swap** (Ollama → OpenAI/Claude) is interface-only in v1; implement
  the backend and set `BACKEND=openai`. The cleanup handler is unchanged.
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