/**
 * Razorpay subscriptions for SunoFlow.
 *
 * The single rule this file exists to enforce: **plan state is written only
 * here, from a signature-verified webhook.** The dashboard can express an
 * intent ("activate", "cancel") but never decides the outcome — otherwise
 * anyone with a browser console could grant themselves a subscription.
 *
 * Flow
 *   1. Dashboard calls createSubscription → we create (or reuse) a Razorpay
 *      customer and subscription, and hand back its id.
 *   2. Dashboard opens Razorpay Checkout with that id; the user authorises a
 *      mandate (card / UPI autopay / netbanking).
 *   3. Razorpay calls razorpayWebhook as things happen. That — and only that —
 *      moves `plan` in Firestore.
 *
 * The trial is ours, not Razorpay's: `trialEndsAt` is set at sign-up and no
 * payment details are collected until the user chooses to subscribe. So a
 * subscription created here starts charging immediately.
 */
import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import Razorpay from "razorpay";
import crypto from "node:crypto";

// Region is set per function rather than relying on setGlobalOptions in
// index.js: ES module imports are evaluated before the importing module's body,
// so anything defined here would otherwise land in the default us-central1 —
// where the dashboard, which looks in asia-south1, would never find it.
const REGION = "asia-south1";

const RAZORPAY_KEY_ID = defineSecret("RAZORPAY_KEY_ID");
const RAZORPAY_KEY_SECRET = defineSecret("RAZORPAY_KEY_SECRET");
const RAZORPAY_WEBHOOK_SECRET = defineSecret("RAZORPAY_WEBHOOK_SECRET");
/** The ₹99/month plan created once in the Razorpay dashboard or via API. */
const RAZORPAY_PLAN_ID = defineSecret("RAZORPAY_PLAN_ID");

const db = () => getFirestore();

function client() {
  return new Razorpay({
    key_id: RAZORPAY_KEY_ID.value(),
    key_secret: RAZORPAY_KEY_SECRET.value(),
  });
}

/* ------------------------------------------------------------- create */

export const createSubscription = onCall(
  { region: REGION, secrets: [RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, RAZORPAY_PLAN_ID] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");

    const userRef = db().doc(`users/${uid}`);
    const snap = await userRef.get();
    if (!snap.exists) throw new HttpsError("failed-precondition", "No account yet.");
    const user = snap.data();

    // Already paying? Hand back the existing subscription rather than making a
    // second one — a duplicate mandate would charge the user twice.
    if (user.plan === "active" && user.razorpaySubscriptionId) {
      return {
        subscriptionId: user.razorpaySubscriptionId,
        keyId: RAZORPAY_KEY_ID.value(),
        alreadyActive: true,
      };
    }

    const rzp = client();

    let customerId = user.razorpayCustomerId;
    if (!customerId) {
      const customer = await rzp.customers.create({
        name: user.displayName || "SunoFlow user",
        email: user.email || undefined,
        fail_existing: 0,          // reuse a customer with the same email
        notes: { uid },
      });
      customerId = customer.id;
      await userRef.set({ razorpayCustomerId: customerId }, { merge: true });
    }

    // If the trial is still running, the first charge is deferred to the day it
    // ends. The mandate is authorised now, but someone who subscribes on day 2
    // of a seven-day trial keeps the five days they were promised instead of
    // paying for them again. Razorpay wants start_at comfortably in the future,
    // so anything closer than a few minutes just starts now.
    const trialEndsAt = user.trialEndsAt?.toMillis?.() ?? 0;
    const startAt = trialEndsAt > Date.now() + 5 * 60_000
      ? Math.floor(trialEndsAt / 1000)
      : undefined;

    let subscription;
    try {
      subscription = await rzp.subscriptions.create({
        plan_id: RAZORPAY_PLAN_ID.value(),
        customer_id: customerId,
        total_count: 120,          // 10 years of monthly cycles; cancel ends it
        customer_notify: 1,
        ...(startAt ? { start_at: startAt } : {}),
        notes: { uid },
      });
    } catch (err) {
      const description = err?.error?.description || err?.message || "Couldn't start the subscription.";
      throw new HttpsError("failed-precondition", description);
    }

    // Recorded so the webhook can find the account, and so a retry reuses it.
    await userRef.set(
      {
        razorpaySubscriptionId: subscription.id,
        billingStatus: subscription.status,
      },
      { merge: true }
    );

    return {
      subscriptionId: subscription.id,
      keyId: RAZORPAY_KEY_ID.value(),
      alreadyActive: false,
      firstChargeAt: startAt ?? null,   // unix seconds, or null for "now"
    };
  }
);

/* ------------------------------------------------------------- cancel */

export const cancelSubscription = onCall(
  { region: REGION, secrets: [RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");

    const userRef = db().doc(`users/${uid}`);
    const snap = await userRef.get();
    const subId = snap.data()?.razorpaySubscriptionId;
    if (!subId) throw new HttpsError("failed-precondition", "No subscription to cancel.");

    const rzp = client();
    const sub = await rzp.subscriptions.fetch(subId);

    // cancel_at_cycle_end only works while a billing cycle is actually running.
    // A subscription authorised during a trial has its first charge deferred, so
    // there is no cycle yet and Razorpay rejects the request outright with
    // "Subscription cannot be cancelled since no billing cycle is going on".
    // Nothing has been paid in that state, so cancelling immediately is both
    // accepted and the honest outcome.
    const cycleRunning = Boolean(sub.current_start) && sub.paid_count > 0;

    try {
      await rzp.subscriptions.cancel(subId, cycleRunning);
    } catch (err) {
      // Surface Razorpay's own wording rather than a bare INTERNAL, which tells
      // the user nothing and tells us almost as little.
      const description = err?.error?.description || err?.message || "Cancellation failed.";
      throw new HttpsError("failed-precondition", description);
    }

    if (cycleRunning) {
      // Access continues to the end of the period already paid for.
      await userRef.set({ cancelAtPeriodEnd: true }, { merge: true });
    } else {
      // Ended before any charge. Re-read from Razorpay so the stored state is
      // whatever actually happened, not what we assumed.
      const after = await rzp.subscriptions.fetch(subId);
      await applySubscription(uid, after, "manual.cancel");
    }
    return { ok: true, immediate: !cycleRunning };
  }
);

export const resumeSubscription = onCall(
  { region: REGION, secrets: [RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");
    // Razorpay has no "un-cancel": a cancelled subscription is finished, so
    // resuming means authorising a fresh mandate. The dashboard sends the user
    // back through checkout.
    throw new HttpsError(
      "unimplemented",
      "Start a new subscription to resume — a cancelled mandate can't be revived."
    );
  }
);

/* ------------------------------------------------------------ webhook */

/** Maps a Razorpay subscription status onto what SunoFlow enforces. */
function planFor(status) {
  switch (status) {
    case "active":
    case "authenticated":
    case "pending":       // payment retrying; keep access while Razorpay retries
      return "active";
    case "halted":        // retries exhausted
    case "cancelled":
    case "completed":
    case "expired":
      return "canceled";
    default:
      return null;        // created / unknown — do not touch the plan
  }
}

/**
 * Applies a Razorpay subscription entity to the account. The single place that
 * writes `plan`, used by both the webhook and the reconcile path so the two can
 * never disagree about what a status means.
 */
async function applySubscription(uid, sub, eventName) {
  let plan = planFor(sub.status);

  // A subscription ending does not cancel a trial that has not run out. Someone
  // who subscribes on day two and changes their mind on day three still has
  // four days left, and must not be locked out of them.
  if (plan === "canceled") {
    const existing = (await db().doc(`users/${uid}`).get()).data() || {};
    const trialEndsAt = existing.trialEndsAt?.toMillis?.() ?? 0;
    if (trialEndsAt > Date.now()) plan = "trial";
  }

  const update = {
    billingStatus: sub.status,
    razorpaySubscriptionId: sub.id,
    lastBillingEvent: eventName,
    lastBillingEventAt: FieldValue.serverTimestamp(),
  };
  if (plan) update.plan = plan;
  if (sub.current_end) {
    update.currentPeriodEnd = Timestamp.fromMillis(sub.current_end * 1000);
  } else if (sub.charge_at) {
    // Before the first charge (a subscription authorised during a trial) there
    // is no current_end yet; the next charge date is the meaningful boundary.
    update.currentPeriodEnd = Timestamp.fromMillis(sub.charge_at * 1000);
  }
  if (eventName === "subscription.cancelled" || sub.status === "cancelled") {
    update.cancelAtPeriodEnd = false;
  }
  await db().doc(`users/${uid}`).set(update, { merge: true });
  return plan;
}

/**
 * Re-reads the subscription from Razorpay and applies it.
 *
 * A webhook that never arrives — a wrong secret, a bad URL, an outage — would
 * otherwise leave someone who has paid stuck on an inactive account with no way
 * out. This makes that recoverable instead of terminal.
 */
export const syncSubscription = onCall(
  { region: REGION, secrets: [RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");

    const snap = await db().doc(`users/${uid}`).get();
    const subId = snap.data()?.razorpaySubscriptionId;
    if (!subId) return { ok: true, plan: snap.data()?.plan ?? "trial", checked: false };

    const sub = await client().subscriptions.fetch(subId);
    if (sub.notes?.uid && sub.notes.uid !== uid) {
      throw new HttpsError("permission-denied", "That subscription belongs to another account.");
    }
    const plan = await applySubscription(uid, sub, "manual.sync");
    return { ok: true, plan: plan ?? snap.data()?.plan, status: sub.status, checked: true };
  }
);

export const razorpayWebhook = onRequest(
  { region: REGION, secrets: [RAZORPAY_WEBHOOK_SECRET], cors: false },
  async (req, res) => {
    if (req.method !== "POST") return res.status(405).send("method not allowed");

    // The signature is over the RAW body. Parsing first and re-serialising
    // would change the bytes and every signature would fail.
    const raw = req.rawBody;
    const signature = req.get("X-Razorpay-Signature") || "";
    const expected = crypto
      .createHmac("sha256", RAZORPAY_WEBHOOK_SECRET.value())
      .update(raw)
      .digest("hex");

    const ok =
      signature.length === expected.length &&
      crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
    if (!ok) {
      console.warn("razorpay webhook: bad signature", {
        eventId: req.get("X-Razorpay-Event-Id") || null,
        // Which secret is in play, without ever logging the secret itself.
        secretFingerprint: crypto
          .createHash("sha256")
          .update(RAZORPAY_WEBHOOK_SECRET.value())
          .digest("hex")
          .slice(0, 8),
        signaturePrefix: signature.slice(0, 8),
      });
      return res.status(401).send("bad signature");
    }

    const event = JSON.parse(raw.toString("utf8"));
    const eventId = req.get("X-Razorpay-Event-Id") || event.id || "";

    // Razorpay retries until it gets a 2xx, so the same event arrives more than
    // once. Claim it first; if it is already claimed, acknowledge and stop.
    if (eventId) {
      const seen = db().doc(`webhookEvents/${eventId}`);
      try {
        await seen.create({ at: FieldValue.serverTimestamp(), type: event.event });
      } catch {
        return res.status(200).send("duplicate");
      }
    }

    const sub = event.payload?.subscription?.entity;
    if (!sub) return res.status(200).send("ignored");

    const uid = sub.notes?.uid;
    if (!uid) {
      console.warn("razorpay webhook: subscription has no uid note", sub.id);
      return res.status(200).send("no uid");
    }

    await applySubscription(uid, sub, event.event);
    console.log("razorpay webhook applied", { event: event.event, uid, status: sub.status });
    return res.status(200).send("ok");
  }
);
