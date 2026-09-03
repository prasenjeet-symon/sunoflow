/**
 * Transactional email, sent through Resend (resend.com).
 *
 * Kept strictly out of plan state: this module can send mail and nothing else.
 * Templates are React Email components under emails/, compiled from .jsx to
 * .js by `npm run build` — which runs on `npm install` and again as the
 * functions predeploy hook (see firebase.json).
 *
 * Setup
 *   1. firebase functions:secrets:set RESEND_API_KEY
 *   2. Verify your sending domain in the Resend dashboard, then put
 *      RESEND_FROM="SunoFlow <hello@yourdomain>" in functions/.env.
 *      The default (onboarding@resend.dev) only ever delivers to the Resend
 *      account's own address; it exists so dev works on day one.
 */
import { defineSecret, defineString } from "firebase-functions/params";

/** Bearer key for the Resend REST API. */
export const RESEND_API_KEY = defineSecret("RESEND_API_KEY");

/** "Name <addr>" — the domain must be verified in Resend before use. */
export const RESEND_FROM = defineString("RESEND_FROM", {
  default: "SunoFlow <onboarding@resend.dev>",
});

const RESEND_API = "https://api.resend.com/emails";

/** True when a Resend key is set. False = every caller runs in dry-run mode. */
export function mailConfigured() {
  return RESEND_API_KEY.value().length > 0;
}

/**
 * Sends one email. Throws on any failure — the caller decides how to react
 * (the notify sweep logs and moves on; the next hourly run retries for free,
 * because its per-user guard flag is only written after a successful send).
 */
export async function sendMail({ to, subject, html, text }) {
  const apiKey = RESEND_API_KEY.value();
  if (!apiKey) throw new Error("sendMail: RESEND_API_KEY is not set");

  const res = await fetch(RESEND_API, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: RESEND_FROM.value(),
      to: [to],
      subject,
      html,
      text,
    }),
  });

  if (!res.ok) {
    const detail = (await res.text().catch(() => "")).slice(0, 300);
    throw new Error(`Resend ${res.status}: ${detail}`);
  }
  return res.json();
}