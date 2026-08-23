# Turning on trial / subscription enforcement

Until `FIREBASE_PROJECT` is set the gateway enforces **nothing**: it serves any
key in its own SQLite table and never looks at a subscription. These are the
steps that change that.

## 1. Get a service-account credential

The gateway needs to read `apiKeys` and `users` in Firestore, and to stamp
`lastSeenAt` on a device. Two ways to get a key; the second is the one to use on
a server.

**Quick (broad permissions).** Firebase Console → ⚙ *Project settings* →
*Service accounts* → **Generate new private key**. Downloads a JSON. This is the
Firebase Admin SDK account and it can do far more than the gateway needs.

**Least privilege (recommended).**

1. https://console.cloud.google.com/iam-admin/serviceaccounts?project=sunoflow-app
2. **Create service account** — name it `sunoflow-gateway`
3. Grant it the single role **Cloud Datastore User**
   (`roles/datastore.user` — read and write Firestore, nothing else)
4. Open the account → **Keys** → *Add key* → *Create new key* → **JSON**

Either way you end up with one JSON file. It is a credential: it is not in git,
it does not belong in the repo, and anyone holding it can read every account.

## 2. Put it on the server

Everything from here runs **on the server** that hosts `cleanup.mirrorli.art`,
not on your Mac. The only thing you do locally is build the binary, and only if
you deploy the systemd way.

```bash
sudo install -d -o sunoflow -g sunoflow -m 750 /etc/sunoflow
sudo install -o sunoflow -g sunoflow -m 400 ~/sunoflow-gateway-*.json \
     /etc/sunoflow/firebase.json
```

Mode `400`, owned by the service user: readable by the gateway, by nobody else.

## 3. Point the gateway at it

Add to `/etc/sunoflow/gateway.env` (systemd) or `.env` (Docker):

```
FIREBASE_PROJECT=sunoflow-app
FIREBASE_CREDENTIALS=/etc/sunoflow/firebase.json
```

## 4. Deploy

### If you run it with Docker Compose

`FIREBASE_CREDENTIALS` is the **host** path; compose mounts it read-only at
`/run/secrets/firebase.json` inside the container and sets the in-container path
for you. Nothing else to change.

```bash
# on the server
git pull
docker compose up -d --build
```

### If you run it under systemd

The binary is Go with a pure-Go SQLite driver, so it cross-compiles cleanly —
but it must be built **for the server's OS and architecture**. Building on an
Apple Silicon Mac without setting these produces a `darwin/arm64` binary that
will not run on a Linux server.

```bash
# on your Mac — pick the arch that matches the server (uname -m there)
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o sunoflow-gateway ./cmd/gateway
scp sunoflow-gateway youruser@yourserver:/tmp/

# on the server
sudo install -m 755 /tmp/sunoflow-gateway /usr/local/bin/sunoflow-gateway
sudo systemctl restart sunoflow-gateway
```

Or simply `git pull && go build` on the server itself, which sidesteps the
cross-compilation question entirely.

## 5. Check it took

**From anywhere, including your Mac** — the response body says which build is
answering, so you do not need shell access to tell:

```bash
curl -s -X POST https://cleanup.mirrorli.art/cleanup \
  -H "Authorization: Bearer sf_not_a_real_key" \
  -H "Content-Type: application/json" \
  -d '{"text":"probe"}'
```

| Response | Meaning |
|---|---|
| `{"error":"unauthorized"}` | old build — entitlement **off** |
| `{"error":"invalid_key","message":"…"}` | new build — entitlement **on** |

**On the server**, the startup log is definitive:

```bash
# systemd
journalctl -u sunoflow-gateway -n 20 --no-pager | grep -i account
# docker
docker compose logs gateway --tail 20 | grep -i account
```

Expect `account entitlement enabled  project=sunoflow-app`.

If instead you see `FIREBASE_PROJECT not set — subscriptions are NOT enforced`,
the env file was not picked up and nothing is being checked.

## What changes the moment it restarts

| Caller | Before | After |
|---|---|---|
| Paired device, trial in date | 401 (key unknown) | **served** |
| Paired device, trial expired | 401 | **402** + "Your free trial has ended" |
| Paired device, subscription active | 401 | **served** |
| Paired device, disconnected from the account | 401 | **401** "This device was disconnected" |
| Pre-pairing key (the shared one in `server.py`) | served | **401 — removed 2026-08-21** |

The migration window is closed. The shared key that used to ship inside every
install has been deleted from `sidecar/server.py` and `sidecars/shared/cleanup.py`,
and `NewMux` is passed `nil` instead of a legacy lookup, so a key Firestore does
not know is refused outright. Every caller must be a paired device on an account
in good standing.

An install that has not paired has no key at all: the app refuses to record and
points the user at Settings → Account.

## Offline leases

Speech-to-text runs on the user's own machine, so the `/cleanup` call is the
only thing standing between an expired account and a working product. That made
the sidecar's "soft-fail to raw text when the gateway is unreachable" rule — the
right behaviour for an outage — into the cheapest bypass there was: point
`cleanup.mirrorli.art` at localhost in `/etc/hosts` and dictation is free
forever, silently.

Every entitled response now carries a signed **lease**, valid 72 hours, which
the sidecar stores. When it cannot reach the gateway it keeps working only while
an unexpired lease is on disk, and refuses once it lapses. A genuine outage stays
invisible — no plausible downtime outlasts three days, and every successful call
mints a fresh lease — while a host blocked on purpose stops working that week.

**Deploy the gateway before the sidecars.** A lease-aware sidecar talking to a
gateway that does not issue leases banks nothing, so the first network blip
blocks that user instead of falling back to raw text — stricter than the design
intends, and it looks like an outage of ours. Ship this gateway first, confirm
`/entitlement` returns a `lease` field, and only then roll out the sidecar
builds. (Rotating `LEASE_SECRET` later is the opposite order — see below.)

Nothing to configure. `LEASE_SECRET` exists to rotate the signing key, and
almost no deployment should set it:

```
# optional; the built-in default is what ships in every sidecar
LEASE_SECRET=
```

Leases are signed with HMAC and the sidecar verifies them with the same value,
so **changing this without shipping a matching sidecar build invalidates every
lease in the field** — users would be cut off the first time the gateway
hiccupped. Ship the sidecar first, then the gateway. See
`internal/account/lease.go` for why this is not really a secret and what the
asymmetric upgrade would look like.

## Notes

- Decisions are cached for 60s, so a disconnect takes up to a minute to bite.
- If Firestore is unreachable the gateway answers **503**, never 401 — an outage
  must not look to the user like a cancelled subscription. The sidecar treats
  503 as an outage too, so a valid lease carries the user through it.
- **Every refusal stops the dictation, 401 and 402 alike.** The two codes differ
  only in the wording the user sees ("your credentials are wrong" vs "you need
  to pay"); a client that resumes on one but not the other serves a disconnected
  device for free, which is exactly the bug this shipped with. The rule both
  sidecars implement: 401/403/402 carrying a JSON `error` body is a hard stop;
  429, 5xx and transport failures are outages and defer to the lease.
