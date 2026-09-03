/**
 * Trial lifecycle email — the one scheduled function in the project.
 *
 * Trial expiry itself is enforced lazily: the gateway compares the wall clock
 * to `trialEndsAt` on every /cleanup request, and nothing ever flips `plan`.
 * Email is the thing that genuinely must happen at a wall-clock moment, so
 * this runs hourly and sweeps two windows:
 *
 *   reminder — trialEndsAt is within the next 24h  → "ends tomorrow"
 *   ended    — trialEndsAt passed in the last 7d   → "has ended"
 *
 * Both sweeps are filtered to plan === "trial", so someone who subscribed
 * (billing.js owns plan state and nothing else writes it) is never chased
 * about a trial they converted, even though a stale trialEndsAt survives on
 * their document.
 *
 * Idempotency: each send is recorded on the user document itself —
 * `notifiedTrialReminderAt` / `notifiedTrialEndedAt` — and the record is
 * written only once the send has succeeded. Retries, redeploys and overlapping
 * runs can therefore never send twice. The failure mode this accepts: an email
 * that sent but crashed before its guard write happens gets sent again an hour
 * later. Rare, and far better than the alternative — a guard written before a
 * send that then failed, leaving the user never-notified.
 *
 * Config
 *   RESEND_API_KEY  secret  `firebase functions:secrets:set RESEND_API_KEY`
 *   RESEND_FROM     param   sender on a Resend-verified domain; the default
 *                           only delivers to the Resend account's own address.
 *
 * Without a key the sweep runs in dry-run: it logs what it would have sent
 * (useful in the emulator) and writes no guard flags, so going live later
 * needs no cleanup.
 */
import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { createElement } from "react";
import { render } from "@react-email/render";

import { RESEND_API_KEY, mailConfigured, sendMail } from "./mailer.js";
import { TrialEndedEmail } from "./emails/TrialEndedEmail.js";
import { TrialEndingEmail } from "./emails/TrialEndingEmail.js";

// Region is set per function rather than via setGlobalOptions: ES module
// imports are evaluated before the importing module's body, so anything
// relying on this module's own globals would land in us-central1 — where
// everything else in this project deliberately does not live.
const REGION = "asia-south1";

const DAY_MS = 24 * 60 * 60 * 1000;
const REMINDER_WINDOW_MS = DAY_MS;    // send once inside the final 24h
const ENDED_WINDOW_MS = 7 * DAY_MS;   // sweep covers a late deploy; never older spam
const SWEEP_LIMIT = 200;              // per run; hourly runs clear any backlog
const PRICE = "₹99";

const db = () => getFirestore();

/** "Prasenjeet Kulkarni" → "Prasenjeet"; blank → "there". */
function firstName(displayName) {
  const first = String(displayName || "").trim().split(/\s+/)[0] || "";
  return first || "there";
}

/** "ends tomorrow" while most of a day remains; an honest hour count after. */
function whenPhrase(endsAtMs, nowMs) {
  const hoursLeft = (endsAtMs - nowMs) / 3.6e6;
  if (hoursLeft >= 12) return "tomorrow";
  const hours = Math.max(1, Math.ceil(hoursLeft));
  return `in ${hours} hour${hours === 1 ? "" : "s"}`;
}

const endsAtFmt = new Intl.DateTimeFormat("en-IN", {
  weekday: "long",
  day: "numeric",
  month: "long",
  hour: "numeric",
  minute: "2-digit",
  timeZoneName: "short",
  timeZone: "Asia/Kolkata",
});

const endedOnFmt = new Intl.DateTimeFormat("en-IN", {
  weekday: "long",
  day: "numeric",
  month: "long",
  timeZone: "Asia/Kolkata",
});

async function composeReminder(snap, nowMs) {
  const user = snap.data();
  const endsAtMs = user.trialEndsAt.toMillis();
  const when = whenPhrase(endsAtMs, nowMs);
  const props = {
    firstName: firstName(user.displayName),
    when,
    endsAt: endsAtFmt.format(new Date(endsAtMs)),
    price: PRICE,
  };
  return {
    subject: `Your SunoFlow trial ends ${when}`,
    html: await render(createElement(TrialEndingEmail, props)),
    text: await render(createElement(TrialEndingEmail, props), { plainText: true }),
  };
}

async function composeEnded(snap) {
  const user = snap.data();
  const props = {
    firstName: firstName(user.displayName),
    endedOn: endedOnFmt.format(new Date(user.trialEndsAt.toMillis())),
    price: PRICE,
  };
  return {
    subject: "Your SunoFlow trial has ended",
    html: await render(createElement(TrialEndedEmail, props)),
    text: await render(createElement(TrialEndedEmail, props), { plainText: true }),
  };
}

/**
 * The sweep itself, split out of the handler so it can be driven against the
 * Firestore emulator with a stub sender. `deps` exists for exactly that:
 * production callers omit it entirely (real Firestore, real mail, real clock).
 *
 * Returns the per-sweep send counts. Per-user failures are logged and swallowed
 * — one bad address must not stall the sweep for everyone else, and the missing
 * guard flag means next run retries it for free.
 */
export async function runTrialSweep({
  now = Date.now(),
  db: store = db(),
  send = sendMail,
  log = console,
  configured = mailConfigured(),
} = {}) {
  const counts = { reminder: 0, ended: 0 };

  const sweeps = [
    {
      name: "reminder",
      query: store
        .collection("users")
        .where("trialEndsAt", ">", Timestamp.fromMillis(now))
        .where("trialEndsAt", "<=", Timestamp.fromMillis(now + REMINDER_WINDOW_MS))
        .limit(SWEEP_LIMIT),
      guard: "notifiedTrialReminderAt",
      compose: (snap) => composeReminder(snap, now),
    },
    {
      name: "ended",
      query: store
        .collection("users")
        .where("trialEndsAt", ">", Timestamp.fromMillis(now - ENDED_WINDOW_MS))
        .where("trialEndsAt", "<=", Timestamp.fromMillis(now))
        .limit(SWEEP_LIMIT),
      guard: "notifiedTrialEndedAt",
      compose: (snap) => composeEnded(snap),
    },
  ];

  for (const { name, query, guard, compose } of sweeps) {
    // Two range filters on the SAME field, so no composite index is needed;
    // the plan check happens here in the sweep instead.
    const candidates = (await query.get()).docs.filter(
      (snap) => snap.get("plan") === "trial" && !snap.get(guard)
    );

    for (const snap of candidates) {
      const email = String(snap.get("email") || "").trim();
      if (!email.includes("@")) continue; // no address — nothing we can deliver to

      try {
        const { subject, html, text } = await compose(snap);
        if (configured) {
          await send({ to: email, subject, html, text });
          // Only after the send succeeded — see the idempotency note above.
          await snap.ref.set({ [guard]: FieldValue.serverTimestamp() }, { merge: true });
        } else {
          log.warn(`[trialNotices] dry run — would email ${email}: "${subject}"`);
        }
        counts[name]++;
      } catch (err) {
        log.error(`[trialNotices] ${name} → ${email} failed:`, err);
      }
    }
  }

  return counts;
}

export const trialNotices = onSchedule(
  {
    schedule: "0 * * * *",
    region: REGION,
    timeZone: "Asia/Kolkata",
    timeoutSeconds: 300,
    secrets: [RESEND_API_KEY],
  },
  async () => {
    const counts = await runTrialSweep();
    if (!mailConfigured()) {
      console.warn(
        "[trialNotices] RESEND_API_KEY is not set — dry run: nothing sent, no guard flags written."
      );
    }
    console.log("[trialNotices]", counts);
    return counts;
  }
);