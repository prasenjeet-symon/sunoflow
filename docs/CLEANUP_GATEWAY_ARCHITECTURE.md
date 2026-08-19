# SunoFlow Cleanup Gateway — Technical Architecture

**Status:** Draft v1 · **Date:** 2026-08-19
**Owner:** Prasenjeet
**Stack decision:** Go (v1 gateway) behind Nginx, fronting a local Ollama instance.

---

## 1. Purpose & scope

SunoFlow's on-device STT (Parakeet via the bundled Python sidecar) runs locally on each user's Mac. The **cleanup/LLM pass** — the step that removes filler words, fixes punctuation, applies formatting cues, and corrects mis-transcribed names — is **server-hosted**, not local. End users do not install or run Ollama.

This document specifies the middleware service that sits between SunoFlow clients (and any future client) and the cleanup LLM. It:

1. Authenticates every request with a per-install API key.
2. Exposes a dedicated **`/cleanup`** endpoint with a stable, backend-agnostic contract — so the underlying LLM (Ollama → OpenAI → Claude) can be swapped without touching any client.
3. Applies per-key **rate limiting / quotas**.
4. Builds the cleanup prompt identically to the existing local sidecar (so behaviour does not regress when cleanup moves to the server).
5. Falls back to the raw transcript on any backend failure — dictation never breaks because cleanup is down.

### v1 scope (this document)

- `/cleanup` endpoint + auth + rate limiting (the cleanup-as-a-service path).
- A general `/chat` passthrough to Ollama is **specified** but marked **v1.1** — not built in v1 unless explicitly requested.
- Single Ollama backend (`OllamaBackend`). The `Backend` interface is defined now so OpenAI/Claude drop in later without rework.

### Out of scope (v1)

- OpenAI/Claude backend implementations (interface only).
- A billing/usage dashboard UI.
- Multi-instance horizontal scaling (single-node + SQLite is the v1 target; Redis-backed limiter noted as the scale path).

---

## 2. High-level architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  SunoFlow app (macOS) ── or any future client (Windows, Android)  │
│  Calls  POST https://api.<domain>/cleanup                         │
│  Header: Authorization: Bearer <api-key>                          │
└───────────────────────────────┬──────────────────────────────────┘
                                │  HTTPS
                                ▼
                        ┌───────────────┐
                        │    Nginx       │  TLS termination
                        │                │  gzip, connection limits
                        │                │  edge rate-limit ( coarse )
                        │                │  proxy_pass → 127.0.0.1:8080
                        └───────┬────────┘
                                │  HTTP (loopback only)
                                ▼
                ┌───────────────────────────────────┐
                │   Cleanup Gateway (Go binary)      │
                │   :8080                            │
                │                                   │
                │   ┌─────────────────────────────┐ │
                │   │ Auth middleware             │ │  verify Bearer key
                │   │  → reject 401 early         │ │  against key store
                │   └────────────┬────────────────┘ │
                │                ▼                  │
                │   ┌─────────────────────────────┐ │
                │   │ Rate limiter (per key)      │ │  token bucket
                │   │  → 429 + Retry-After       │ │  golang.org/x/time/rate
                │   └────────────┬────────────────┘ │
                │                ▼                  │
                │   ┌─────────────────────────────┐ │
                │   │ Router                      │ │
                │   │  /health  /ready            │ │  no auth (Nginx checks)
                │   │  /cleanup → CleanupHandler  │ │
                │   │  /chat    → ChatHandler (v1.1)│ │
                │   └────────────┬────────────────┘ │
                │                ▼                  │
                │   ┌─────────────────────────────┐ │
                │   │ Backend interface           │ │  OllamaBackend (v1)
                │   │  Cleanup(text,ctx,recent,   │ │  OpenAIBackend  (later)
                │   │         screen) (string,err) │ │  ClaudeBackend  (later)
                │   └────────────┬────────────────┘ │
                └────────────────┼──────────────────┘
                                 │  HTTP (loopback only)
                                 ▼
                        ┌────────────────┐
                        │  Ollama :11434  │  binds 127.0.0.1 only
                        │  (never exposed │  never reachable from
                        │   to internet)  │  outside the host
                        └────────────────┘
```

**Key boundary:** Ollama binds to `127.0.0.1` only and is never directly reachable from the internet. Nginx is the only internet-facing listener. The Go gateway is the sole caller of Ollama. This is the single most important security property of the system.

---

## 3. Component responsibilities

### 3.1 Nginx (edge)

- **TLS termination** — the only place a private key lives. Cert via Let's Encrypt / certbot, auto-renewed.
- **Coarse protection** — connection limits, request-body size cap (`client_max_body_size 1m` — cleanup payloads are tiny), slowloris mitigation via `proxy_*` timeouts.
- **Edge rate limiting** — `limit_req` zone per client IP as a blunt shield against abuse that bypasses the API-key layer (e.g. unauthenticated `/health` flooding). The fine-grained per-key limit lives in the Go gateway.
- **Upstream health check** — `proxy_next_upstream` off (single upstream); use `/ready` for active checks if a load balancer is added later.
- **Header hygiene** — strip `Server`, set `X-Content-Type-Options: nosniff`, forward `X-Request-Id` (generated by the gateway) for tracing.

### 3.2 Cleanup Gateway (Go)

The gateway is a single static binary run under systemd. Its layers, in request order:

| Layer | Responsibility | Failure mode |
|---|---|---|
| **Auth** | Verify `Authorization: Bearer <key>` against the key store; attach key identity to request context. | `401 Unauthorized` |
| **Rate limiter** | Per-key token bucket; reject over-quota. | `429 Too Many Requests` + `Retry-After` |
| **Router** | Route to handler; generate/propagate `X-Request-Id`. | `404` |
| **CleanupHandler** | Validate body, build prompt, call `Backend.Cleanup`, apply echo-retry guard, fall back to raw text. | `200` with `{cleaned: raw}` on backend failure |
| **Backend (OllamaBackend)** | Call `127.0.0.1:11434/api/generate`, parse NDJSON, collect response. | error → caller falls back |

### 3.3 Ollama (backend)

- Runs on the same host, `OLLAMA_HOST=127.0.0.1:11434`.
- Model pulled/managed on the server (e.g. `glm-5.2:cloud` or `llama3.2:3b` — the production model is a server-side config decision, not client-controlled).
- The gateway talks to it over loopback HTTP only.

---

## 4. Tech stack decision — Go

| Requirement | Go | Node.js (Fastify) | Python (FastAPI) |
|---|---|---|---|
| Throughput / concurrency | **Best** — goroutines | Very good | Good, heavier per-conn |
| Memory footprint | **Lowest** — one static binary | Moderate | Highest |
| Streaming Ollama NDJSON | Trivial (`io.Copy`, `ReverseProxy`) | Trivial | Fine (`StreamingResponse`) |
| Deploy behind Nginx | **One binary, zero runtime** | Needs Node runtime | Needs Python + venv |
| Auth / rate-limit / DB ecosystem | Good, more verbose | **Richest** | Good |
| New language for this project | Yes | Yes | Already in use |

**Decision: Go.** v1 is a focused gateway (auth + proxy + rate limit + cleanup endpoint). That is the textbook `httputil.ReverseProxy` / `net/http` use case: best throughput, smallest artifact, trivial concurrency, zero runtime to install on the server. The gateway is I/O-bound on Ollama anyway, so the gateway itself is never the bottleneck — but Go still gives the lowest per-connection overhead and the smallest attack surface.

Fastify is the comfortable second if, later, this grows into a heavier application (user accounts, billing, dashboard). It is **not** chosen for v1.

Python is **not** chosen for this public-facing role despite being used for the local STT sidecar: that sidecar is single-user local work; a public gateway wants lower per-connection overhead and a smaller surface than uvicorn/gunicorn.

---

## 5. API contract

All endpoints are JSON. Base URL: `https://api.<domain>`. Auth (where required) is `Authorization: Bearer <api-key>`.

### 5.1 `POST /cleanup`  (v1 — primary endpoint)

Takes a raw transcript plus optional reference material and returns the cleaned text. The prompt is built **server-side** so the client never sends the cleanup instruction — only the data.

**Request**
```json
{
  "text":    "um so I think we should um ship this on friday",
  "context": "",
  "recent":  [],
  "screen":  ""
}
```
| Field | Type | Required | Notes |
|---|---|---|---|
| `text` | string | yes | The raw STT transcript to clean. |
| `context` | string | no | Text already written before the cursor (reference only). |
| `recent` | string[] | no | The user's last few cleaned dictations (reference only). |
| `screen` | string | no | OCR words from the user's screen (reference only). |

**Response** `200 OK`
```json
{ "cleaned": "So I think we should ship this on Friday." }
```

**Semantics (must match the existing local sidecar exactly):**
- Empty/whitespace `text` → return `{cleaned: ""}` without calling the backend.
- On backend error, timeout, or echo-detection failure → return `{cleaned: <raw text>}`. **Never** return an error status for a cleanup failure; dictation must always succeed with at least the raw transcript.
- The echo-retry guard runs server-side (see §7.2).

**Errors**
- `400 Bad Request` — malformed JSON or missing `text`.
- `401 Unauthorized` — missing/invalid API key.
- `429 Too Many Requests` — rate limit hit; `Retry-After: <seconds>` header set.
- `502`/`504` — **not used for cleanup failures** (those fall back to raw text, HTTP 200). Only returned if the gateway itself is broken.

### 5.2 `GET /health`  (no auth)

Liveness probe for Nginx / monitoring.
```json
{ "status": "ok" }
```

### 5.3 `GET /ready`  (no auth)

Readiness probe — checks Ollama reachability.
```json
{ "status": "ready", "backend": "ollama", "backend_ok": true }
```
`backend_ok: false` → gateway is up but cannot serve cleanup; Nginx/upstream checker can drain traffic.

### 5.4 `POST /chat`  (v1.1 — specified, not built in v1)

Raw passthrough to Ollama `/api/generate` with the same auth + rate limit. Useful for arbitrary LLM use beyond cleanup. **Deferred** unless explicitly requested.

### 5.5 Admin endpoints (v1 — minimal)

Key management is intentionally simple in v1. Endpoints are protected by a separate admin token (env var `ADMIN_TOKEN`), not a user API key.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/admin/keys` | Issue a new API key → returns the key once. |
| `GET` | `/admin/keys` | List key ids + metadata (never the secret). |
| `DELETE` | `/admin/keys/{id}` | Revoke a key. |

---

## 6. Authentication & key storage

### 6.1 Key model

- Each SunoFlow install is issued an **API key** (opaque random token, ≥ 32 bytes, base64url-encoded).
- The key is sent as `Authorization: Bearer <key>`.
- The gateway stores a **hash** of the key (SHA-256), never the plaintext. The plaintext is shown to the operator once at issuance and then only to whoever was issued it.
- A key has: `id` (UUID), `hash`, `label` (optional, e.g. "Prasenjeet's MBP"), `created_at`, `revoked_at`, and quota fields (§8).

### 6.2 Storage (v1)

**SQLite** — a single file on the gateway host (`/var/lib/sunoflow-gateway/keys.db`). Sufficient for v1's single-node deployment; no concurrency pressure (reads are cached, writes are rare admin actions).

Schema (sketch):
```sql
CREATE TABLE keys (
  id          TEXT PRIMARY KEY,          -- UUID
  key_hash    TEXT NOT NULL UNIQUE,      -- SHA-256 hex
  label       TEXT,
  created_at  INTEGER NOT NULL,
  revoked_at  INTEGER,
  quota_rpm   INTEGER NOT NULL DEFAULT 60,   -- requests / minute
  quota_daily INTEGER NOT NULL DEFAULT 5000  -- requests / day
);
CREATE TABLE usage (
  key_id      TEXT NOT NULL,
  day         TEXT NOT NULL,             -- YYYY-MM-DD
  count       INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (key_id, day)
);
```

**Scale path:** swap SQLite for Postgres + a Redis-backed rate limiter when multi-instance is needed. The `Backend`/auth interfaces are designed so this is a storage swap, not a rewrite.

### 6.3 Privacy

Transcripts are user voice text sent to a remote server. This is an inherent tradeoff of hosted cleanup and **must** be documented to users:
- All traffic is HTTPS (TLS terminated at Nginx).
- The gateway logs **metadata only** (request id, key id, latency, status) — **not** transcript contents.
- Transcripts are not persisted; they exist in memory for the duration of the request and are discarded.
- The cleanup instruction is server-owned, so the client sends only the transcript + reference text, never the system prompt.

---

## 7. Cleanup logic — ported from the local sidecar

The gateway **must** produce identical cleanup behaviour to the current local `sidecar/server.py`. This section is the spec for that port.

### 7.1 Prompt builder

Reproduces `build_cleanup_prompt(text, context, recent, screen)` from `server.py`:

```
<cleanup_instruction>

[SCREEN — words visible on screen near the input field; reference only, do NOT repeat or edit]
<screen>

[CONTEXT — already written before the cursor; reference only, do NOT repeat or edit]
<context>

[RECENT DICTATION — the user's last few dictations; reference only]
- <recent[0]>
- <recent[1]>

[NEW TRANSCRIPT — output ONLY the cleaned version of this]
<text>

Cleaned transcript:
```

- Each bracketed section is included **only if** its input is non-empty.
- The `cleanup_instruction` is the server-controlled system prompt (the `CLEANUP_RULES` constant in `server.py`, ~70 lines covering filler removal, formatting cues, emoji substitution, and the anti-prompt-injection rules). It is **not** sent by the client.
- Sections are joined with `\n`.

### 7.2 Echo-retry guard

Reproduces `_looks_like_echo` + the retry in `clean_with_ollama`:

1. Call the backend with the full prompt (context + recent + screen).
2. If the result is non-empty **and** passes the echo check → return it.
3. If it looks like an echo (the model regurgitated reference material) → **retry with no context/recent/screen** (context-free prompt).
4. If the retry is non-empty and not too long → return it.
5. Otherwise → return the raw `text` unchanged.

**Echo detection** (`_looks_like_echo`):
- `len(cleaned) > len(text)*1.5 + 30` → echo (real cleanup only ever shortens or lightly edits).
- Any `recent` entry of length ≥ 15 found verbatim in `cleaned` → echo.
- `context` (length ≥ 20): its last 40 chars found in `cleaned` → echo.
- `screen` (length ≥ 40): its last 40 chars found in `cleaned` → echo.

**Retry length guard:** `len(cleaned) <= len(text)*1.5 + 30`.

### 7.3 Ollama call

Reproduces `_ollama_generate`:
- `POST 127.0.0.1:11434/api/generate`
- JSON body: `{ "model": <server model>, "prompt": <built prompt>, "stream": false, "options": { "temperature": 0.0 } }`
- Timeout: 20s (v1; configurable).
- Response field: `response` (trimmed).

### 7.4 What stays client-side

The following are **not** the gateway's job and remain in the on-device sidecar:
- STT (Parakeet).
- The learned **corrections dictionary** (`apply_corrections`) — applied locally as the final step, after the server returns cleaned text. This keeps personal corrections on-device.
- `recent_transcripts` history — maintained client-side and sent as `recent` per request. (The server is stateless per key.)

> **Note:** this means the client flow becomes: STT → POST `/cleanup` → apply local corrections → insert text. The server returns the LLM-cleaned text; the client layers corrections on top, exactly as `server.py` does today.

---

## 8. Rate limiting & quotas

- **Algorithm:** token bucket per API key, `golang.org/x/time/rate`.
- **Defaults:** 60 requests/minute, 5000 requests/day (overridable per key in the store).
- **Response on exceed:** `429 Too Many Requests` with `Retry-After: <seconds>`.
- **Daily quota:** tracked in the `usage` table (one row per key per day). Checked before the token bucket; reset at UTC midnight.
- **Edge limit (Nginx):** a coarse per-IP `limit_req` as a first line against unauthenticated flooding.

---

## 9. Backend abstraction

```go
type Backend interface {
    Cleanup(ctx context.Context, prompt string) (string, error)
    Name() string
    Healthy(ctx context.Context) bool
}
```

- **`OllamaBackend`** (v1): implements `Cleanup` via the `/api/generate` call in §7.3.
- **`OpenAIBackend`** / **`ClaudeBackend`** (later): implement the same interface against their chat-completions APIs. The `CleanupHandler` is unaware of which backend is active.
- **Selection:** config-driven (`BACKEND=ollama|openai|claude`). The handler resolves the backend from the server config at request time (no client change needed to switch).
- The system prompt (`cleanup_instruction`) is owned by the server and injected into `build_cleanup_prompt` regardless of backend — so swapping backends does not change prompt construction, only the transport.

---

## 10. Configuration

All config is environment-variable driven (12-factor), loaded at startup. No config in the binary.

| Var | Default | Purpose |
|---|---|---|
| `GATEWAY_ADDR` | `127.0.0.1:8080` | Listen address (loopback; Nginx proxies to it). |
| `OLLAMA_URL` | `http://127.0.0.1:11434/api/generate` | Ollama generate endpoint. |
| `OLLAMA_MODEL` | `llama3.2:3b` | Model name (server-controlled). |
| `BACKEND` | `ollama` | Active backend. |
| `OLLAMA_TIMEOUT` | `20s` | Per-call timeout. |
| `DB_PATH` | `/var/lib/sunoflow-gateway/keys.db` | SQLite path. |
| `ADMIN_TOKEN` | — | Token for `/admin/*` endpoints. Required. |
| `LOG_LEVEL` | `info` | `debug`/`info`/`warn`/`error`. |
| `DEFAULT_QUOTA_RPM` | `60` | Default per-key rate. |
| `DEFAULT_QUOTA_DAILY` | `5000` | Default per-key daily cap. |

The **cleanup instruction** (the `CLEANUP_RULES` text) is a compile-time constant in the gateway, mirroring `server.py`. If it needs to be runtime-editable later, it moves to a config file — but v1 keeps it in source, version-controlled, identical to the sidecar's.

---

## 11. Observability

- **Structured logging** (JSON to stdout, for systemd/journald): `request_id`, `key_id`, `method`, `path`, `status`, `latency_ms`, `backend`, `backend_ok`. **No transcript contents.**
- **`/health`** and **`/ready`** for liveness/readiness.
- **Request IDs:** the gateway generates a UUID per request, logs it, and sets `X-Request-Id` on the response. Nginx forwards it. This is the tracing key across logs.
- **Metrics (v1.1):** Prometheus `/metrics` (request count, latency histogram, backend latency, 429 count). Not required for v1 launch but trivial to add with `prometheus/client_golang`.

---

## 12. Security considerations

| Concern | Mitigation |
|---|---|
| Ollama exposed to internet | Binds `127.0.0.1` only; gateway is sole caller. Nginx never proxies to it directly. |
| Transcript eavesdropping | TLS at Nginx; HSTS header. |
| Transcript persistence | None — in-memory only, discarded after response. Logs exclude contents. |
| Key leakage | Store SHA-256 hashes only; plaintext shown once at issuance. |
| Prompt injection | The `CLEANUP_RULES` instruction is server-owned and never sent by the client; the transcript is framed as data, not instructions (see the anti-injection clauses already in `CLEANUP_RULES`). |
| DoS / abuse | Per-IP edge limit (Nginx) + per-key token bucket + daily quota + `client_max_body_size 1m`. |
| Backend compromise | Gateway validates/trims Ollama responses; echo guard prevents regurgitation of reference material. |
| Admin endpoint exposure | Separate `ADMIN_TOKEN`; ideally `/admin/*` bound to a separate Nginx location with IP allowlist. |

---

## 13. Project structure (proposed)

```
cleanup-gateway/
  go.mod
  cmd/gateway/main.go            # wiring: load config, start server
  internal/
    config/                      # env loading
    auth/                        # key store (SQLite), middleware
    ratelimit/                   # per-key token bucket + daily quota
    backend/                     # Backend interface
      ollama.go                  # OllamaBackend (v1)
    cleanup/                     # prompt builder + echo guard (ported from sidecar)
    server/                      # handlers, router, middleware chain
    store/                       # SQLite access (keys, usage)
  deploy/
    nginx.conf                   # TLS, proxy_pass, limits
    gateway.service              # systemd unit
    README.md                    # deploy runbook
```

---

## 14. Nginx configuration (sketch)

```nginx
# /etc/nginx/sites-available/sunoflow
limit_req_zone $binary_remote_addr zone=edge:10m rate=30r/s;

server {
    listen 443 ssl http2;
    server_name api.<domain>;

    ssl_certificate     /etc/letsencrypt/live/api.<domain>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.<domain>/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    client_max_body_size 1m;

    # Public API
    location / {
        limit_req zone=edge burst=60 nodelay;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Request-Id $request_id;
        proxy_read_timeout 30s;
    }

    # Admin — IP allowlist (v1)
    location /admin/ {
        allow <operator-ip>;
        deny all;
        proxy_pass http://127.0.0.1:8080;
    }
}

server {
    listen 80;
    server_name api.<domain>;
    return 301 https://$host$request_uri;
}
```

---

## 15. Build order / milestones

1. **Skeleton** — Go module, `net/http` server on `:8080`, `/health`, `/ready`, `/cleanup` stub returning raw text. Structured logging + request IDs.
2. **OllamaBackend** — call `127.0.0.1:11434/api/generate`, parse response, return text. Wire into `/cleanup`.
3. **Cleanup logic port** — port `build_cleanup_prompt` + `_looks_like_echo` + the retry/fallback from `server.py` into `internal/cleanup`. Verify byte-for-byte prompt parity with the sidecar.
4. **Auth middleware** — SQLite key store, Bearer verification, `/admin/keys` CRUD.
5. **Rate limiter** — per-key token bucket + daily quota table; `429` + `Retry-After`.
6. **Nginx config** — TLS, `proxy_pass`, edge limits, admin allowlist.
7. **Backend interface extraction** — lift the Ollama call behind `Backend`; add config-driven selection. (OpenAI/Claude stubs, not implemented.)
8. **Hardening** — request timeouts, max body, systemd unit, deploy runbook, observability review.

**Definition of done (v1):** a SunoFlow client can POST a raw transcript to `https://api.<domain>/cleanup` with a Bearer key and receive cleaned text identical to what the local Ollama sidecar produces today, with auth, rate limiting, and raw-text fallback on any backend failure.

---

## 16. Open questions (to resolve before/ during build)

1. **Key issuance UX** — manual admin endpoint (v1 plan) vs. a self-serve signup flow? For v1 launch with a small set of users, manual issuance is fine.
2. **Streaming** — v1 uses collect-then-respond (simpler, enables fallback). If latency is noticeable on long transcripts, switch `/cleanup` to stream tokens from Ollama through the gateway. Decision deferred until measured.
3. **Cleanup instruction ownership** — v1 keeps it server-side (compile-time constant). If it needs per-user customization later, move to a server config file keyed by `key_id`. Not needed for v1.
4. **Model choice** — `glm-5.2:cloud` (current sidecar config) vs. `llama3.2:3b` (default). This is a server-side operational decision; the gateway reads it from `OLLAMA_MODEL` and the client is unaware.
5. **Multi-region / scaling** — single host + SQLite for v1. Redis + Postgres when a second host is added. Not now.

---

## 17. Glossary

- **Gateway** — the Go middleware service described here.
- **Sidecar** — the existing on-device Python FastAPI service (`sidecar/server.py`) running Parakeet STT locally on the user's Mac.
- **Cleanup** — the LLM pass that tidies a raw transcript (filler removal, punctuation, formatting cues, name correction).
- **Backend** — the LLM the gateway calls to perform cleanup (Ollama in v1; OpenAI/Claude later).