# SunoFlow Cleanup Gateway — Technical Architecture

**Status:** Draft v1 · **Date:** 2026-08-19
**Owner:** Prasenjeet
**Stack decision:** Go (v1 gateway) behind Nginx, calling the Gemini API.

---

## 1. Purpose & scope

SunoFlow's on-device STT (Parakeet via the bundled Python sidecar) runs locally on each user's Mac. The **cleanup/LLM pass** — the step that removes filler words, fixes punctuation, applies formatting cues, and corrects mis-transcribed names — is **server-hosted**, not local. End users install no model runtime and hold no provider credentials.

This document specifies the middleware service that sits between SunoFlow clients (and any future client) and the cleanup LLM. It:

1. Authenticates every request with a per-install API key.
2. Exposes a dedicated **`/cleanup`** endpoint with a stable, backend-agnostic contract — so the underlying LLM can be swapped without touching any client.
3. Applies per-account **rate limiting / quotas**.
4. Builds the cleanup prompt identically to the existing local sidecar (so behaviour does not regress when cleanup moves to the server).
5. Falls back to the raw transcript on any backend failure — dictation never breaks because cleanup is down.

### v1 scope (this document)

- `/cleanup` endpoint + auth + rate limiting (the cleanup-as-a-service path).
- A general `/chat` passthrough to the backend is **specified** but marked **v1.1** — not built in v1 unless explicitly requested.
- Single Gemini backend (`GeminiBackend`). The `Backend` interface is defined so another provider drops in later without rework.

### Out of scope (v1)

- Any second backend implementation (the interface is the extension point).
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
                │   │ Rate limiter (per account)  │ │  token bucket
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
                │   │ Backend interface           │ │  GeminiBackend (v1)
                │   │  Cleanup(prompt)            │ │  another provider
                │   │         (string, err)       │ │  drops in behind this
                │   └────────────┬────────────────┘ │
                └────────────────┼──────────────────┘
                                 │  HTTPS + API key
                                 ▼
                    ┌─────────────────────────┐
                    │  Gemini API             │  generativelanguage
                    │  generateContent        │  .googleapis.com
                    │  (key never leaves      │
                    │   the gateway)          │
                    └─────────────────────────┘
```

**Key boundary:** the provider API key lives only in the gateway's environment and is never sent to, or derivable by, a client. Nginx is the only internet-facing listener; the gateway accepts no inbound traffic except from it. This is the single most important security property of the system — it is the whole reason cleanup is server-side rather than in the app.

---

## 3. Component responsibilities

### 3.1 Nginx (edge)

- **TLS termination** — the only place a private key lives. Cert via Let's Encrypt / certbot, auto-renewed.
- **Coarse protection** — connection limits, request-body size cap (`client_max_body_size 1m` — cleanup payloads are tiny), slowloris mitigation via `proxy_*` timeouts.
- **Edge rate limiting** — `limit_req` zone per client IP as a blunt shield against abuse that bypasses the API-key layer (e.g. unauthenticated `/health` flooding). The fine-grained per-account limit lives in the Go gateway.
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
| **Backend (GeminiBackend)** | Call `generativelanguage.googleapis.com` `generateContent`, collect the response text. | error → caller falls back |

### 3.3 Gemini (backend)

- Google's hosted API — nothing to install, pull, or keep warm on the server. The gateway's only external dependency is outbound HTTPS.
- Model is a server-side config decision, not client-controlled (`GEMINI_MODEL`, default `gemini-3.5-flash-lite`).
- `GEMINI_THINKING_LEVEL` is pinned low: cleanup is mechanical, so any chain-of-thought the model emits before answering is pure latency on the dictation path. Reasoning-heavy models measured 6-24s per cleanup against roughly 1s here for the same output.
- The API key is read from the environment at startup. The gateway refuses to boot without it, rather than silently degrading every cleanup to raw text.

---

## 4. Tech stack decision — Go

| Requirement | Go | Node.js (Fastify) | Python (FastAPI) |
|---|---|---|---|
| Throughput / concurrency | **Best** — goroutines | Very good | Good, heavier per-conn |
| Memory footprint | **Lowest** — one static binary | Moderate | Highest |
| Streaming backend responses | Trivial (`io.Copy`, `ReverseProxy`) | Trivial | Fine (`StreamingResponse`) |
| Deploy behind Nginx | **One binary, zero runtime** | Needs Node runtime | Needs Python + venv |
| Auth / rate-limit / DB ecosystem | Good, more verbose | **Richest** | Good |
| New language for this project | Yes | Yes | Already in use |

**Decision: Go.** v1 is a focused gateway (auth + proxy + rate limit + cleanup endpoint). That is the textbook `httputil.ReverseProxy` / `net/http` use case: best throughput, smallest artifact, trivial concurrency, zero runtime to install on the server. The gateway is I/O-bound on the LLM provider anyway, so the gateway itself is never the bottleneck — but Go still gives the lowest per-connection overhead and the smallest attack surface.

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
  "screen":  "",
  "tone":    "professional",
  "dictionary": [
    {"from": "cavach", "to": "Kavach", "kind": "correction"},
    {"from": "my Instagram", "to": "https://instagram.com/someone", "kind": "expansion"}
  ]
}
```
| Field | Type | Required | Notes |
|---|---|---|---|
| `text` | string | yes | The raw STT transcript to clean. |
| `context` | string | no | Text already written before the cursor (reference only). |
| `recent` | string[] | no | The user's last few cleaned dictations (reference only). |
| `screen` | string | no | OCR words from the user's screen (reference only). |
| `tone` | string | no | ID of the writing voice the user picked — one of `professional`, `formal`, `casual`, `friendly`, `concise`, `confident`. Absent, empty, or unrecognised → the faithful default, which leaves the user's wording alone. |
| `dictionary` | object[] | no | The user's own saved terms — `{from, to, kind}`, `kind` ∈ `correction`\|`expansion` (missing/unknown → `correction`). Unlike the other fields this one is *acted on*, not just referenced. Capped at `cleanup.MaxEntries` (64); blank entries dropped. |

**On the dictionary.** It lives only on the user's machine. The sidecar sends
just the entries that look relevant to the transcript in hand, so a dictation
that touches none of them carries no `dictionary` field at all. The gateway
holds them for the length of the request: they are never persisted, and the
logging middleware logs no request bodies. See §7.1 for how they reach the
prompt and `docs/CONTRACT.md` for what the two kinds mean.

**On the tone.** The client sends an *ID*, never wording: `"formal"`, not the
instruction that produces formal output. The gateway owns every instruction the
model sees (§7.1), so this field selects a row from a server-side table and can
never supply text of its own — an ID the gateway does not serve normalizes to
the faithful tone rather than erroring. That is also what an older client which
never sends the field gets, and what the whole installed base got before tones
existed: the faithful prompt is byte-for-byte the one that shipped before, and
the user's own wording survives untouched.

A tone is the one thing that licenses rewording, and it licenses nothing else.
The voice may change *how* something is said; it may not add a fact, a greeting
or a sign-off the speaker did not dictate, change how certain a claim is, or
translate. See `internal/cleanup/tone.go`.

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

Readiness probe — checks backend reachability.
```json
{ "status": "ready", "backend": "gemini", "backend_ok": true }
```
`backend_ok: false` → gateway is up but cannot serve cleanup; Nginx/upstream checker can drain traffic.

### 5.4 `POST /chat`  (v1.1 — specified, not built in v1)

Raw passthrough to the active backend with the same auth + rate limit. Useful for arbitrary LLM use beyond cleanup. **Deferred** unless explicitly requested.

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

`BuildPrompt(text, context, recent, screen, dict, tone)`:

```
<cleanup_instruction>

[TONE — the voice the user asked for; applies to the NEW TRANSCRIPT only]
<shared rewriting limits>
THE REQUESTED VOICE — PROFESSIONAL:
<voice definition>

[DICTIONARY — the user's own saved terms; reference only, do NOT repeat or edit]
SPELLINGS (what the transcript mis-hears -> how the user writes it):
- "cavach" -> "Kavach"
SHORTHAND (what the user says out loud -> the value it stands for):
- "my Instagram" -> "https://instagram.com/someone"

[SCREEN — words visible anywhere on the user's screen; reference only, do NOT repeat or edit]
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

- Each bracketed section is included **only if** its input is non-empty. Within the dictionary block, each half (SPELLINGS / SHORTHAND) is omitted when it has no entries — a heading with nothing under it invites the model to invent one.
- The dictionary comes **first**: it is the user's own authority on their own words, and outranks anything inferred from the screen or the surrounding text.
- The `cleanup_instruction` is the server-controlled system prompt (the `CleanupRules` constant in `internal/cleanup/cleanup.go`, covering filler removal, formatting cues, emoji substitution, the DICTIONARY rules, and the anti-prompt-injection rules). It is **not** sent by the client.
- Sections are joined with `\n`.

**Why the dictionary needs prompt rules rather than a find-and-replace.** A
correction is mechanical, and the sidecar does apply those itself after cleanup.
An expansion is not: "here's my Instagram" should become the URL, and "I don't
have an Instagram" must not. Only something reading the sentence can tell those
apart, which is why expansions exist as a distinct kind that only the model ever
applies. The prompt's DICTIONARY block spells out that distinction, tells the
model to reproduce a value byte-for-byte rather than tidying it, and defaults to
leaving the words alone when the intent is unclear.

### 7.2 Echo-retry guard

Reproduces `_looks_like_echo` + the retry in `clean_with_gateway`:

1. Call the backend with the full prompt (dictionary + context + recent + screen).
2. If the result is non-empty **and** passes the echo check → return it.
3. If it looks like an echo (the model regurgitated reference material) → **retry with no context/recent/screen**, but **keeping the dictionary and the tone**. Those three are the bulky, noisy sources that actually get echoed; the dictionary and the tone are short, structured, and the things the user explicitly asked us to apply, so dropping either would silently switch the feature off on exactly the dictations that needed a second attempt — and a retry that reverted to the faithful voice would read to the user as the tone key having missed the press.
4. If the retry is non-empty and not too long → return it.
5. Otherwise → return the raw `text` unchanged.

**Echo detection** (`LooksLikeEcho`):
- `len(cleaned) > len(text)*growth(tone) + 30 + expansionAllowance` → echo.
- Any of the dictionary or tone section headers found in `cleaned` → echo, at any length.
- Any `recent` entry of length ≥ 15 found verbatim in `cleaned` → echo.
- `context` (length ≥ 20): its last 40 chars found in `cleaned` → echo.
- `screen` (length ≥ 40): its last 40 chars found in `cleaned` → echo.

**Retry length guard:** `len(cleaned) <= len(text)*growth(tone) + 30 + expansionAllowance`.

**`growth(tone)`** is 1.5 for the faithful default — the original guard, unchanged
— and up to 2.0 for the voices that may legitimately add words (see
`internal/cleanup/tone.go`). The 1.5x rests on cleanup only ever *removing*
words, which a tone breaks; in practice ordinary rewrites still land well inside
it, so the extra room is headroom for a premise that no longer holds rather than
a fix for an observed failure. It costs the guard nothing that matters: real
echoes overshoot by multiples, not by 60%, and the substring rules catch them at
any tone.

**`expansionAllowance`** is the total length of the `expansion` values offered in
this request. The length rule works because cleanup normally only ever removes
words — but a shorthand substitution trades three spoken words for a
sixty-character URL, so without budgeting for the values the model was given,
the guard rejects a correct result and the dictation falls back to raw text.

### 7.3 Backend call

`GeminiBackend.Cleanup`:
- `POST {GEMINI_URL}/models/{model}:generateContent` with the API key.
- The **whole** built prompt goes in as a single user part — not split into `systemInstruction` + user content. Keeping the prompt provider-agnostic is deliberate: a future backend can be swapped in without re-tuning it.
- `temperature: 0` and thinking pinned to `GEMINI_THINKING_LEVEL` (default `low`).
- Timeout: 20s (configurable via `GEMINI_TIMEOUT`).
- Response: the first candidate's text part (trimmed).

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

- **`GeminiBackend`** (v1): implements `Cleanup` via the `generateContent` call in §7.3. It is the only implementation.
- **A future backend** implements the same interface against its own API. The `CleanupHandler` is unaware of which backend is active; adding one means writing the implementation and adding a case in `cmd/gateway/main.go`.
- **Selection:** config-driven (`BACKEND`). `gemini` is currently the only accepted value — anything else is rejected at startup as a typo rather than accepted and then failed at request time.
- The system prompt (`cleanup_instruction`) is owned by the server and injected into `build_cleanup_prompt` regardless of backend — so swapping backends does not change prompt construction, only the transport.

---

## 10. Configuration

All config is environment-variable driven (12-factor), loaded at startup. No config in the binary.

| Var | Default | Purpose |
|---|---|---|
| `GATEWAY_ADDR` | `127.0.0.1:8080` | Listen address (loopback; Nginx proxies to it). |
| `BACKEND` | `gemini` | Active backend. Only `gemini` is accepted. |
| `GEMINI_API_KEY` | — | Provider API key. **Required** — startup fails without it. |
| `GEMINI_MODEL` | `gemini-3.5-flash-lite` | Model name (server-controlled). |
| `GEMINI_URL` | `https://generativelanguage.googleapis.com/v1beta` | API base; override for tests. |
| `GEMINI_TIMEOUT` | `20s` | Per-call timeout. |
| `GEMINI_THINKING_LEVEL` | `low` | `minimal`/`low`/`medium`/`high`; empty omits the field. |
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
| Provider API key leakage | The key lives only in the gateway's environment, is never logged, and never reaches a client. This is why cleanup is server-side at all. |
| Transcript eavesdropping | TLS at Nginx; HSTS header. |
| Transcript persistence | None — in-memory only, discarded after response. Logs exclude contents. |
| Key leakage | Store SHA-256 hashes only; plaintext shown once at issuance. |
| Prompt injection | The `CLEANUP_RULES` instruction is server-owned and never sent by the client; the transcript is framed as data, not instructions (see the anti-injection clauses already in `CLEANUP_RULES`). |
| DoS / abuse | Per-IP edge limit (Nginx) + per-key token bucket + daily quota + `client_max_body_size 1m`. |
| Malicious/degenerate backend output | Gateway validates and trims the response; the echo guard prevents regurgitation of reference material, and any failure falls back to the raw transcript. |
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
      gemini.go                  # GeminiBackend (v1)
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
2. **GeminiBackend** — call `generateContent`, parse the response, return text. Wire into `/cleanup`.
3. **Cleanup logic port** — port `build_cleanup_prompt` + `_looks_like_echo` + the retry/fallback from `server.py` into `internal/cleanup`. Verify byte-for-byte prompt parity with the sidecar.
4. **Auth middleware** — SQLite key store, Bearer verification, `/admin/keys` CRUD.
5. **Rate limiter** — per-key token bucket + daily quota table; `429` + `Retry-After`.
6. **Nginx config** — TLS, `proxy_pass`, edge limits, admin allowlist.
7. **Backend interface extraction** — lift the provider call behind `Backend`; add config-driven selection via `BACKEND`.
8. **Hardening** — request timeouts, max body, systemd unit, deploy runbook, observability review.

**Definition of done (v1):** a SunoFlow client can POST a raw transcript to `https://api.<domain>/cleanup` with a Bearer key and receive cleaned text, with auth, rate limiting, and raw-text fallback on any backend failure — and without the client holding any provider credential.

---

## 16. Open questions (to resolve before/ during build)

1. **Key issuance UX** — manual admin endpoint (v1 plan) vs. a self-serve signup flow? For v1 launch with a small set of users, manual issuance is fine.
2. **Streaming** — v1 uses collect-then-respond (simpler, enables fallback). If latency is noticeable on long transcripts, switch `/cleanup` to stream tokens from the backend through the gateway. Decision deferred until measured.
3. **Cleanup instruction ownership** — v1 keeps it server-side (compile-time constant). If it needs per-user customization later, move to a server config file keyed by `key_id`. Not needed for v1.
4. **Model choice** — settled on `gemini-3.5-flash-lite` with thinking at its floor, on measured latency (roughly 1s vs 6-24s for reasoning-heavy models). This stays a server-side operational decision; the gateway reads it from `GEMINI_MODEL` and the client is unaware.
5. **Multi-region / scaling** — single host + SQLite for v1. Redis + Postgres when a second host is added. Not now.

---

## 17. Glossary

- **Gateway** — the Go middleware service described here.
- **Sidecar** — the existing on-device Python FastAPI service (`sidecar/server.py`) running Parakeet STT locally on the user's Mac.
- **Cleanup** — the LLM pass that tidies a raw transcript (filler removal, punctuation, formatting cues, name correction).
- **Backend** — the LLM the gateway calls to perform cleanup (Gemini in v1; another provider drops in behind the same interface).