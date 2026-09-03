/**
 * Integration check for runTrialSweep against the Firestore emulator.
 * Run: firebase emulators:exec --only firestore "node scripts/emulator-check.mjs"
 * (firebase.json wires --only firestore here; see the exec command in BUILD docs.)
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

process.env.FIRESTORE_EMULATOR_HOST = "127.0.0.1:8099";
process.env.GCLOUD_PROJECT = "demo-notify";

initializeApp({ projectId: "demo-notify" });
const db = getFirestore();

const { runTrialSweep } = await import("../notify.js");

const NOW = Date.now();
const HOUR = 3.6e6;

/** Seeds one user doc. `plan` defaults to trial; `email` always present unless omitted. */
async function seed(id, trialEndsAt, extra = {}) {
  await db.doc(`users/${id}`).set({
    uid: id,
    displayName: "Prasenjeet Kulkarni",
    email: `${id}@example.com`,
    plan: "trial",
    trialEndsAt: Timestamp.fromMillis(trialEndsAt),
    ...extra,
  });
}

await seed("u-reminder", NOW + 20 * HOUR);                 // in window → reminded
await seed("u-reminder-2h", NOW + 2 * HOUR);               // in window → "in 2 hours"
await seed("u-early", NOW + 96 * HOUR);                    // 4 days out → untouched
await seed("u-ended", NOW - 26 * HOUR);                    // in window → ended email
await seed("u-ended-old", NOW - 30 * 24 * HOUR);           // 30d past → untouched
await seed("u-active", NOW + 5 * HOUR, { plan: "active" }); // subscribed → untouched
await seed("u-done", NOW + 5 * HOUR, {
  notifiedTrialReminderAt: Timestamp.fromMillis(NOW - HOUR), // guard held → untouched
});
await seed("u-noemail", NOW + 5 * HOUR, { email: "" });    // no address → skipped

const sent = [];
const send = async (mail) => { sent.push(mail); };
const log = { warn: () => {}, error: (m, e) => { throw new Error(`${m} ${e.message}`); } };

const counts = await runTrialSweep({ now: NOW, db, send, log, configured: true });

const expectations = [
  ["reminder count", counts.reminder, 2],
  ["ended count", counts.ended, 1],
  ["sent total", sent.length, 3],
];

const subjects = sent.map((m) => `${m.to}: ${m.subject}`).sort();
console.log("sent:", subjects);

const failures = [];
for (const [name, got, want] of expectations) {
  if (got !== want) failures.push(`${name}: got ${got}, want ${want}`);
}
if (!subjects.some((s) => s.includes("u-reminder@example.com") && s.includes("tomorrow"))) {
  failures.push("reminder for u-reminder missing 'tomorrow'");
}
if (!subjects.some((s) => s.includes("u-reminder-2h@example.com") && s.includes("in 2 hours"))) {
  failures.push("reminder for u-reminder-2h missing 'in 2 hours'");
}
if (!subjects.some((s) => s.includes("u-ended@example.com") && s.includes("has ended"))) {
  failures.push("ended email missing");
}

// Guard flags written only for the sent users.
for (const id of ["u-reminder", "u-reminder-2h", "u-ended"]) {
  const doc = await db.doc(`users/${id}`).get();
  if (!doc.get("notifiedTrialReminderAt") && !doc.get("notifiedTrialEndedAt")) {
    failures.push(`${id}: guard flag missing after send`);
  }
}

// Idempotency: a second identical run must send nothing.
const counts2 = await runTrialSweep({ now: NOW, db, send, log, configured: true });
if (counts2.reminder !== 0 || counts2.ended !== 0) {
  failures.push(`second sweep resent mail: ${JSON.stringify(counts2)}`);
}

if (failures.length) {
  console.error("FAILED:\n  " + failures.join("\n  "));
  process.exit(1);
}
console.log("ALL SWEEP CHECKS PASSED (incl. second-run idempotency)");