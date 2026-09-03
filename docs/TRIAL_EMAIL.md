# Trial lifecycle email

Hourly Cloud Function that sends two pieces of mail:

| Email | When | Subject |
|---|---|---|
| Reminder | `trialEndsAt` is within the next 24h | "Your SunoFlow trial ends tomorrow" (or "…in N hours") |
| Ended | `trialEndsAt` passed in the last 7 days | "Your SunoFlow trial has ended" |

Design notes (matching the lazy-enforcement architecture):

- **`trialEndsAt` stays the single source of truth.** The sweep only reads it.
  It never writes `plan` — that remains `billing.js`'s job alone. A user who
  subscribes mid-trial keeps `plan: "active"` and is never mailed, even though
  a stale `trialEndsAt` survives on their document.
- **Idempotent by guard flags.** `notifiedTrialReminderAt` /
  `notifiedTrialEndedAt` are written to the user doc *after* a successful send,
  so redeploys, retries and overlapping runs can never send twice. The accepted
  trade-off: a send that succeeds but crashes before the flag write repeats an
  hour later — rare, and much better than the reverse.
- **Dry-run without a key.** With `RESEND_API_KEY` unset the sweep logs what it
  would send and writes no flags, so enabling the key later needs no cleanup.

## Files

| File | Purpose |
|---|---|
| `functions/emails/*.jsx` | React Email templates + shared shell (`theme.jsx`). Source of truth; compiled to `.js` by the build (compiled output is gitignored). |
| `functions/mailer.js` | Resend sender + `RESEND_API_KEY` secret / `RESEND_FROM` param. |
| `functions/notify.js` | `trialNotices` scheduled function (hourly, Asia/Kolkata) + `runTrialSweep()`, the extracted core. |
| `functions/scripts/preview.mjs` | `npm run preview` — renders both emails to `/tmp` for eyeballing. |
| `functions/scripts/emulator-check.mjs` | Full sweep logic against the Firestore emulator (windows, filtering, guards, idempotency). |

## Setup

```sh
# 1. Resend: verify your sending domain (dashboard → Domains), grab an API key.
# 2. Give the functions the key (do NOT commit it):
cd functions
firebase functions:secrets:set RESEND_API_KEY   # paste the re_... key

# 3. Set the verified sender (default onboarding@resend.dev only delivers
#    to your own Resend account's address):
firebase functions:params:set RESEND_FROM "SunoFlow <hello@yourdomain>"

# 4. Deploy (the predeploy hook compiles the email templates):
firebase deploy --only functions
```

## Verify before go-live

```sh
# Emails as files, no sending:
cd functions && npm run preview
open /tmp/sunoflow-email-trial-ending.html /tmp/sunoflow-email-trial-ended.html

# Sweep logic against the real Firestore emulator:
cd .. && firebase emulators:exec --only firestore --project demo-notify \
  "cd functions && node scripts/emulator-check.mjs"
```

## Changing the copy

Edit `functions/emails/TrialEndingEmail.jsx` / `TrialEndedEmail.jsx`, then
`npm run preview` to check. `firebase deploy --only functions` rebuilds via the
predeploy hook in `firebase.json`.