/**
 * Device pairing for SunoFlow.
 *
 * The flow follows the OAuth device-authorisation shape, which is what Ollama,
 * the GitHub CLI and Apple TV all use, because it needs no OAuth client in the
 * native app and no typing by the user:
 *
 *   1. The Mac app calls  pairDevice   → gets a device_code (secret) and a
 *      short user_code, then opens the browser at /connect.html.
 *   2. The signed-in user approves in the browser → approveDevice writes the
 *      approval and mints an API key.
 *   3. The Mac app, polling pollDevice with its device_code, collects the key
 *      exactly once and stores it in the Keychain.
 *
 * The device_code is the device's bearer secret and is never shown to the user.
 * The user_code is short and human-readable but useless on its own — approving
 * it only helps the device that holds the matching device_code.
 */
import { onRequest, onCall, HttpsError } from "firebase-functions/v2/https";
import { setGlobalOptions } from "firebase-functions/v2";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import crypto from "node:crypto";

initializeApp();
setGlobalOptions({ region: "asia-south1", maxInstances: 10 });

const db = getFirestore();

const PAIRING_TTL_MIN = 10;
const POLL_INTERVAL_SEC = 3;

/** Unambiguous alphabet — no O/0, I/1, so a user reading it aloud can't slip. */
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

function userCode() {
  const pick = (n) =>
    Array.from(crypto.randomBytes(n))
      .map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length])
      .join("");
  return `${pick(4)}-${pick(4)}`;
}

const secret = () => crypto.randomBytes(32).toString("base64url");
const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");

function clean(value, max = 120) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

/* ------------------------------------------------------------------ 1. pair */
/** Called by the Mac app. Returns the codes it needs to start a pairing. */
export const pairDevice = onRequest({ cors: true }, async (req, res) => {
  if (req.method !== "POST") return res.status(405).json({ error: "method_not_allowed" });

  const body = req.body || {};
  const name = clean(body.name) || "Mac";
  const platform = clean(body.platform) || "macOS";
  const appVersion = clean(body.appVersion, 32);

  const deviceCode = secret();
  const code = userCode();
  const expiresAt = Timestamp.fromMillis(Date.now() + PAIRING_TTL_MIN * 60_000);

  // Keyed by a hash of the device_code so the raw secret is never at rest.
  await db.collection("pairings").doc(sha256(deviceCode)).set({
    userCode: code,
    name, platform, appVersion,
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
  });

  res.json({
    device_code: deviceCode,
    user_code: code,
    verification_uri: `https://sunoflow-app.web.app/connect.html?code=${encodeURIComponent(code)}&platform=${(platform || "").toLowerCase().startsWith("win") ? "windows" : "mac"}`,
    interval: POLL_INTERVAL_SEC,
    expires_in: PAIRING_TTL_MIN * 60,
  });
});

/* --------------------------------------------------------------- 2. approve */
/** Called from the dashboard by a signed-in user. */
export const approveDevice = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");

  const code = clean(request.data?.userCode, 16).toUpperCase();
  if (!code) throw new HttpsError("invalid-argument", "Missing code.");

  const found = await db.collection("pairings")
    .where("userCode", "==", code)
    .where("status", "==", "pending")
    .limit(1).get();

  if (found.empty) throw new HttpsError("not-found", "That code isn't valid. It may have expired.");

  const doc = found.docs[0];
  const pairing = doc.data();
  if (pairing.expiresAt.toMillis() < Date.now()) {
    await doc.ref.update({ status: "expired" });
    throw new HttpsError("deadline-exceeded", "That code has expired. Start again in the app.");
  }

  // The key is returned to the device once; only its hash is kept.
  const apiKey = "sf_" + secret();
  const keyId = sha256(apiKey);
  const deviceId = crypto.randomUUID();

  // Create the account if this is the user's first touch. Pairing can happen
  // before they ever open the dashboard — sign-in goes straight back to the
  // connect page — and a device key whose uid has no account document resolves
  // to "no_account", which the gateway refuses. Without this, a brand-new user
  // pairs successfully and then cannot dictate.
  const userRef = db.doc(`users/${uid}`);
  const existing = await userRef.get();

  const batch = db.batch();
  if (!existing.exists) {
    const trialEnds = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
    batch.set(userRef, {
      uid,
      email: request.auth.token.email || "",
      displayName: request.auth.token.name || "",
      photoURL: request.auth.token.picture || "",
      plan: "trial",
      cancelAtPeriodEnd: false,
      currentPeriodEnd: null,
      trialEndsAt: Timestamp.fromDate(trialEnds),
      createdAt: FieldValue.serverTimestamp(),
    });
  }
  batch.set(db.collection("apiKeys").doc(keyId), {
    uid, deviceId,
    createdAt: FieldValue.serverTimestamp(),
    revokedAt: null,
  });
  batch.set(db.doc(`users/${uid}/devices/${deviceId}`), {
    name: pairing.name,
    platform: pairing.platform,
    appVersion: pairing.appVersion,
    keyId,
    createdAt: FieldValue.serverTimestamp(),
    lastSeenAt: null,
  });
  batch.update(doc.ref, {
    status: "approved",
    uid, deviceId,
    apiKey,                       // collected once by the device, then cleared
    approvedAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();

  return { ok: true, device: { name: pairing.name, platform: pairing.platform } };
});

/* ------------------------------------------------------------------ 3. poll */
/** Called by the Mac app until the user approves. */
export const pollDevice = onRequest({ cors: true }, async (req, res) => {
  if (req.method !== "POST") return res.status(405).json({ error: "method_not_allowed" });

  const deviceCode = clean(req.body?.device_code, 200);
  if (!deviceCode) return res.status(400).json({ error: "invalid_request" });

  const ref = db.collection("pairings").doc(sha256(deviceCode));
  const snap = await ref.get();
  if (!snap.exists) return res.status(404).json({ error: "expired_token" });

  const p = snap.data();
  if (p.expiresAt.toMillis() < Date.now()) {
    await ref.delete();
    return res.status(400).json({ error: "expired_token" });
  }
  if (p.status === "pending") return res.status(428).json({ error: "authorization_pending" });
  if (p.status !== "approved") return res.status(400).json({ error: p.status });

  // Hand the key over exactly once, then destroy the pairing record.
  const apiKey = p.apiKey;
  await ref.delete();
  return res.json({ api_key: apiKey, uid: p.uid, device_id: p.deviceId });
});

/* ---------------------------------------------------------------- 4. revoke */
/**
 * Disconnect a device. Deletes the device record and marks its key revoked, so
 * the gateway stops honouring it. Idempotent: revoking twice is not an error.
 *
 * This is a function rather than a client write because the browser has no
 * access to `apiKeys` — if it did, a compromised session could revoke, or
 * un-revoke, anything.
 */
export const revokeDevice = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in first.");

  const deviceId = clean(request.data?.deviceId, 64);
  if (!deviceId) throw new HttpsError("invalid-argument", "Missing device.");

  const ref = db.doc(`users/${uid}/devices/${deviceId}`);
  const snap = await ref.get();
  if (!snap.exists) return { ok: true, alreadyGone: true };

  const { keyId, name } = snap.data();

  const batch = db.batch();
  if (keyId) {
    // Keep the key row, marked revoked, rather than deleting it: the gateway
    // can then tell "revoked" apart from "never existed" when it logs refusals.
    batch.set(
      db.collection("apiKeys").doc(keyId),
      { revokedAt: FieldValue.serverTimestamp(), revokedBy: uid },
      { merge: true }
    );
  }
  batch.delete(ref);
  await batch.commit();

  return { ok: true, name: name || "That device" };
});

/* --------------------------------------------------------------- billing */
// Razorpay subscriptions. Kept in its own module: plan state is written there
// and nowhere else, so there is exactly one place to audit.
export { createSubscription, cancelSubscription, resumeSubscription, syncSubscription, razorpayWebhook }
  from "./billing.js";
