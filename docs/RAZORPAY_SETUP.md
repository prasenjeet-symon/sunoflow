# Razorpay subscriptions — what to set up before this goes live

The code is written and tested against the emulators. Nothing is deployed,
because deploying it without the keys would break the working billing flow.
These are the steps that make it live, in order.

## 1. Create the plan (once)

Razorpay Dashboard → **Subscriptions → Plans → Create Plan**

| Field | Value |
|---|---|
| Billing frequency | Monthly, every 1 month |
| Amount | ₹99 |
| Plan name | SunoFlow Monthly |

Copy the plan id (`plan_XXXXXXXX`).

> The **trial is ours, not Razorpay's** — `trialEndsAt` is set in Firestore at
> sign-up and no card is collected until the user chooses to subscribe. The plan
> therefore has no trial period configured.
>
> Subscribing *during* a trial passes `start_at = trialEndsAt`, so the mandate is
> authorised immediately but the first charge is deferred to the day the trial
> ends. Without that, someone subscribing on day two of a seven-day trial would
> be charged at once and quietly lose the five days they were promised. The
> checkout window names the date the first charge will land.

## 2. Store the secrets

Four values, set with the Firebase CLI. They go to Secret Manager, never into
the repo:

```bash
firebase functions:secrets:set RAZORPAY_KEY_ID       # rzp_test_… to start
firebase functions:secrets:set RAZORPAY_KEY_SECRET
firebase functions:secrets:set RAZORPAY_PLAN_ID      # plan_… from step 1
firebase functions:secrets:set RAZORPAY_WEBHOOK_SECRET
```

The webhook secret is one you invent — any long random string. It has to match
what you type into Razorpay in step 4.

## 3. Deploy

```bash
firebase deploy --only functions,firestore:rules,hosting
```

All three together. The dashboard now calls `createSubscription` instead of
writing to Firestore, and the rules refuse client writes to `plan` — so
deploying any one of them alone leaves the account page broken.

## 4. Point Razorpay at the webhook

Razorpay Dashboard → **Settings → Webhooks → Add New Webhook**

- **URL** `https://asia-south1-sunoflow-app.cloudfunctions.net/razorpayWebhook`
- **Secret** the same string you set as `RAZORPAY_WEBHOOK_SECRET`
- **Active events**

  - `subscription.activated`
  - `subscription.charged`
  - `subscription.pending`
  - `subscription.halted`
  - `subscription.cancelled`
  - `subscription.completed`

## 5. Test with a test-mode card

With `rzp_test_` keys, Razorpay accepts `4111 1111 1111 1111`, any future
expiry, any CVV. Subscribe from the dashboard and watch the plan flip to
**Active** within a few seconds of authorising.

```bash
firebase functions:log --only razorpayWebhook
```

## How states map

Razorpay's subscription status is the source of truth. The webhook — and only
the webhook — writes `plan`:

| Razorpay status | SunoFlow `plan` | Effect |
|---|---|---|
| `authenticated`, `active` | `active` | dictation works |
| `pending` | `active` | payment retrying; access kept during retries |
| `halted` | `canceled` | retries exhausted; dictation stops |
| `cancelled`, `completed`, `expired` | `canceled` | dictation stops |
| `created` | *unchanged* | mandate not authorised yet |

`pending → active` is deliberate: a card that fails on renewal should not cut
someone off mid-sentence while Razorpay is still retrying.

## Things worth knowing

- **Cancellation** uses `cancel_at_cycle_end`, so access lasts to the end of the
  period already paid for — which is what the dashboard promises.
- **Resuming is not un-cancelling.** Razorpay cannot revive a cancelled mandate,
  so "resume" sends the user back through checkout for a fresh one.
- **Webhooks are idempotent.** Razorpay retries until it gets a 2xx; each event
  id is claimed in `webhookEvents/` before processing, and a repeat is answered
  `duplicate` without touching the account.
- **Signatures are verified over the raw body.** Parsing and re-serialising the
  JSON changes the bytes and every signature fails.
- **UPI Autopay / eMandate** may need enabling on your Razorpay account before
  recurring payments work in live mode. Test mode does not require it.
