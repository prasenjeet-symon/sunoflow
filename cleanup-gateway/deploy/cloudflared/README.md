# Cloudflare Tunnel (SunoFlow cleanup gateway)

Exposes the cleanup-gateway stack on a stable HTTPS hostname via a **named
Cloudflare tunnel**, using the `ogcode.xyz` domain.

```
client -> Cloudflare (TLS) -> cloudflared -> nginx :8081 -> gateway :8080 -> Ollama (host)
```

## Public URL

`https://cleanup.ogcode.xyz` — `/health`, `/ready`, `POST /cleanup` (Bearer auth).

## Prerequisites

- `brew install cloudflared`
- `cloudflared tunnel login` (once per machine — writes `~/.cloudflared/cert.pem`,
  the account cert used only for `tunnel create` / `route dns`)

## Files here

| File | Purpose |
|------|---------|
| `config.yml` | Tunnel config — ingress rules + `credentials-file` path |
| `kavachqr-dev.json` | **Tunnel credentials secret — gitignored, never commit** |

## Run the stack + tunnel

```bash
# 1. Bring up the gateway stack (nginx publishes 127.0.0.1:8081)
cd cleanup-gateway
docker compose up -d --build

# 2. The tunnel runs as a LaunchAgent (com.sunoflow.cloudflared) and starts
#    at login. To (re)start it manually:
launchctl kickstart -k gui/$(id -u)/com.sunoflow.cloudflared
```

## Relocating to a new machine

1. `cloudflared tunnel login`
2. Copy `config.yml` + `kavachqr-dev.json` here (chmod 400 the JSON).
3. Update the absolute `credentials-file` path in `config.yml` if the repo
   moved.
4. Install the LaunchAgent:
   ```bash
   cp <repo>/cleanup-gateway/deploy/cloudflared/com.sunoflow.cloudflared.plist \
      ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.sunoflow.cloudflared.plist
   ```
   (Adjust the absolute paths in the plist if the repo isn't at
   `~/Downloads/work/sunoapp`.)

## History

The tunnel `kavachqr-dev` (id `2a9975bd-e8a6-4fe5-b394-e42401b02d0c`) was
originally provisioned for the KavachQR project. When KavachQR was
decommissioned, this config + the credentials were relocated into the
SunoFlow tree so SunoFlow's production endpoint no longer depends on a
decommissioned project's directory. The tunnel NAME is historical and left
as-is — renaming a live tunnel isn't worth the downtime, but the `kavachqr-dev`
label is purely cosmetic and only appears in `cloudflared tunnel list`.

## Notes

- TLS is terminated at Cloudflare; nginx inside the stack is HTTP-only.
- The tunnel secret (`kavachqr-dev.json`) and the account cert
  (`~/.cloudflared/cert.pem`) are both outside version control.
- To change the public subdomain: edit `ingress.hostname` in `config.yml`,
  run `cloudflared tunnel route dns --overwrite-dns kavachqr-dev <new host>`,
  and update `cleanup-gateway`/client config to point at the new URL.