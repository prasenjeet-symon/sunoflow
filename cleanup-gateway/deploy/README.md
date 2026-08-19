# SunoFlow cleanup gateway — deploy runbook

Single-host v1 deployment of the Go cleanup gateway behind Nginx, fronting a
local Ollama. See `docs/CLEANUP_GATEWAY_ARCHITECTURE.md` for the full design.

## Build

```sh
cd cleanup-gateway
go build -o sunoflow-gateway ./cmd/gateway
```

The result is a single static binary. CGO is not required (SQLite via
`modernc.org/sqlite`, a pure-Go driver), so a plain `go build` suffices.

## Prerequisites on the host

1. **Ollama** installed and running, bound to loopback only:
   ```sh
   OLLAMA_HOST=127.0.0.1:11434 ollama serve
   ```
   Pull the model you chose for `OLLAMA_MODEL`:
   ```sh
   ollama pull llama3.2:3b   # or glm-5.2:cloud, etc.
   ```
   **Never** expose Ollama to the internet. It must bind `127.0.0.1` only.

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
OLLAMA_URL=http://127.0.0.1:11434/api/generate
OLLAMA_MODEL=llama3.2:3b              # server-controlled; change without a client release
BACKEND=ollama
OLLAMA_TIMEOUT=20s
DB_PATH=/var/lib/sunoflow-gateway/keys.db
LOG_LEVEL=info
DEFAULT_QUOTA_RPM=60
DEFAULT_QUOTA_DAILY=5000
```

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
# Readiness (checks Ollama)
curl https://api.example.com/ready
# Cleanup
curl -X POST https://api.example.com/cleanup \
  -H "Authorization: Bearer <user-key>" \
  -H "Content-Type: application/json" \
  -d '{"text":"um so I think we should um ship this on friday"}'
# → {"cleaned":"So I think we should ship this on Friday."}
```

## Operational notes

- **Logs** go to journald as JSON: `journalctl -u sunoflow-gateway -f`. They
  contain metadata only (request id, key id, latency, status) — never transcript
  contents.
- **Swap the model** by editing `OLLAMA_MODEL` in `/etc/sunoflow/gateway.env` and
  restarting the service. No client release needed.
- **Backend swap** (Ollama → OpenAI/Claude) is interface-only in v1; implement the
  backend and set `BACKEND=openai`. The cleanup handler is unchanged.
- **Scaling:** v1 is single-host + SQLite. When a second host is needed, move the
  key store to Postgres and the rate limiter to Redis; the interfaces are
  designed so this is a storage swap, not a rewrite.