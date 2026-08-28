# SunoFlow cleanup gateway — deploy runbook

Single-host v1 deployment of the Go cleanup gateway behind Nginx, fronting a
the Gemini API. See `docs/CLEANUP_GATEWAY_ARCHITECTURE.md` for the full design.

## Build

```sh
cd cleanup-gateway
go build -o sunoflow-gateway ./cmd/gateway
```

The result is a single static binary. CGO is not required (SQLite via
`modernc.org/sqlite`, a pure-Go driver), so a plain `go build` suffices.

## Prerequisites on the host

1. **A Gemini API key** from https://aistudio.google.com/apikey, and outbound
   HTTPS from the host to `generativelanguage.googleapis.com`. There is no
   local model runtime to install and nothing to pull — the gateway holds the
   key and is the only process that talks to the provider.

2. **Nginx** with a TLS cert (Let's Encrypt / certbot):
   ```sh
   certbot --nginx -d api.example.com
   ```

3. **SQLite data dir**:
   ```sh
   sudo mkdir -p /var/lib/sunoflow-gateway
   sudo chown sunoflow:sunoflow /var/lib/sunoflow-gateway
   ```

## Configure

Create `/etc/sunoflow/gateway.env`:

```sh
ADMIN_TOKEN=<long random secret>      # REQUIRED. Guards /admin/*.
GATEWAY_ADDR=127.0.0.1:8080
BACKEND=gemini
GEMINI_API_KEY=<AI Studio key>        # REQUIRED. Startup fails without it.
GEMINI_MODEL=gemini-3.5-flash-lite    # server-controlled; change without a client release
GEMINI_TIMEOUT=20s
GEMINI_THINKING_LEVEL=low             # minimal|low|medium|high
DB_PATH=/var/lib/sunoflow-gateway/keys.db
LOG_LEVEL=info
POSTHOG_API_KEY=                      # empty = analytics off, nothing is sent
POSTHOG_HOST=https://us.i.posthog.com # or https://eu.i.posthog.com
DEFAULT_QUOTA_RPM=60
DEFAULT_QUOTA_DAILY=5000
```

Both quotas are **per account**, not per device: a customer who pairs three
machines gets one allowance, not three. Usage is attributed to the account uid
where the gateway knows it (any paired device) and to the key id otherwise (a
legacy key, which belongs to no account).


## Install

```sh
sudo cp sunoflow-gateway /usr/local/bin/
sudo cp deploy/gateway.service /etc/systemd/system/
sudo cp deploy/nginx.conf /etc/nginx/sites-available/sunoflow
sudo ln -sf /etc/nginx/sites-available/sunoflow /etc/nginx/sites-enabled/sunoflow
sudo systemctl daemon-reload
sudo systemctl enable --now sunoflow-gateway
sudo nginx -t && sudo systemctl reload nginx
```

## Issue a key (manual, v1)

```sh
curl -X POST https://api.example.com/admin/keys \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"label":"Prasenjeet MBP"}'
# → {"id":"...","key":"<plaintext-shown-once>","label":"...","created_at":...}
```

Hand the `key` to the user out-of-band. It is shown **once**; only the SHA-256
hash is stored. List keys (metadata only):

```sh
curl -H "Authorization: Bearer $ADMIN_TOKEN" https://api.example.com/admin/keys
```

Revoke:

```sh
curl -X DELETE -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://api.example.com/admin/keys/<id>
```

## Verify

```sh
# Liveness
curl https://api.example.com/health
# Readiness (probes Gemini)
curl https://api.example.com/ready
# Cleanup
curl -X POST https://api.example.com/cleanup \
  -H "Authorization: Bearer <user-key>" \
  -H "Content-Type: application/json" \
  -d '{"text":"um so I think we should um ship this on friday"}'
# → {"cleaned":"So I think we should ship this on Friday."}
```

## Product analytics

`POSTHOG_API_KEY` turns on PostHog reporting; leaving it empty is a full off
switch — no events, no goroutine, no network calls. It is the ingest (project)
key, not a personal API key.

It lives here rather than in the two client apps because every dictation already
passes through this service, the account uid is already resolved here (so "how
many users" is an answer, not a guess from installs), and changing what is
measured is a gateway restart instead of two app releases and a wait for
everyone to update.

Two events:

- `dictation` — one per `/cleanup`. Properties: `os`, `app_version`, `cleanup`,
  `transcript_chars`, `cleaned_chars`, `had_screen`, `had_context`,
  `dictionary_terms`, `latency_ms`.
- `entitlement_check` — one per `/entitlement`. **Not a dictation count.** The
  sidecar caches a successful check for ten minutes, so with cleanup switched
  off this fires roughly once per ten minutes of use rather than once per
  dictation. It exists so a cleanup-off user still appears in the user count;
  their dictation volume is not observable from the server.

`distinct_id` is the account uid, so one customer with three machines is one
user. The OS split comes from the `X-SunoFlow-Client: <os>/<version>` header the
sidecar sends; installs that predate it report `unknown` rather than vanishing.

**What is never sent:** transcript, cleaned text, screen OCR, cursor context,
dictionary entries, audio, IP address. `$ip` is explicitly null, both because
server-side the only IP visible is this host's (which would place every user in
one datacentre) and because it is not ours to collect. A test in
`internal/server/analytics_test.go` posts a dictation full of marker strings and
fails if any of them reach the events payload.

## Operational notes

- **Logs** go to journald as JSON: `journalctl -u sunoflow-gateway -f`. They
  contain metadata only (request id, key id, latency, status) — never transcript
  contents.
- **Swap the model** by editing `GEMINI_MODEL` in `/etc/sunoflow/gateway.env` and
  restarting the service. No client release needed.
- **Adding a backend** means implementing `backend.Backend` and adding a case in
  `cmd/gateway/main.go`; `BACKEND` then selects it. The cleanup handler and the
  prompt are provider-agnostic and stay unchanged.
- **Key hygiene:** `GEMINI_API_KEY` lives only in `/etc/sunoflow/gateway.env`,
  which should be mode 600 and owned by the `sunoflow` user. It is never logged.
- **Scaling:** v1 is single-host + SQLite. When a second host is needed, move the
  key store to Postgres and the rate limiter to Redis; the interfaces are
  designed so this is a storage swap, not a rewrite.