// Firebase bootstrap for the SunoFlow account area.
//
// These values are not secrets — a Firebase web config is public by design, and
// access is controlled by Firestore security rules, not by hiding this file.
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import {
  getAuth, setPersistence, browserLocalPersistence,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";
import { getFirestore } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js";

export const app = initializeApp({
  apiKey: "AIzaSyDDx88HvncYveWw2jWCQIaQ8psT3Y_o4No",
  // The hosting origin, NOT <project>.firebaseapp.com, so sign-in happens on
  // the same origin as the app. Firebase Hosting serves the auth handler at
  // /__/auth/handler on every linked site. Cross-origin the session lands in
  // third-party storage, which browsers partition — pages then disagree about
  // whether you are signed in and /connect.html <-> /login.html ping-pong.
  //
  // Any domain used here must ALSO be listed as an authorized redirect URI on
  // the project's OAuth client, or Google refuses with error 400
  // redirect_uri_mismatch. sunoflow-app.web.app was added on 2026-08-21; a
  // custom domain would need the same treatment.
  authDomain: "sunoflow-app.web.app",
  projectId: "sunoflow-app",
  storageBucket: "sunoflow-app.firebasestorage.app",
  messagingSenderId: "549742162802",
  appId: "1:549742162802:web:b07b2f5f605b9519b2a3eb",
});

export const auth = getAuth(app);
export const db = getFirestore(app);

// When served from localhost, talk to the Firebase emulators instead of the
// real project — so local work can never touch production accounts or data.
const LOCAL = ["localhost", "127.0.0.1"].includes(location.hostname);
if (LOCAL) {
  const { connectAuthEmulator } = await import("https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js");
  const { connectFirestoreEmulator } = await import("https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js");
  connectAuthEmulator(auth, "http://127.0.0.1:9199", { disableWarnings: true });
  connectFirestoreEmulator(db, "127.0.0.1", 8099);
}

// Keep the session across tabs and restarts until the user signs out.
await setPersistence(auth, browserLocalPersistence);

/** Turn a Firebase error code into something a person can act on. */
export function friendlyError(err) {
  const code = (err && err.code) || "";
  switch (code) {
    case "auth/popup-closed-by-user":
    case "auth/cancelled-popup-request":
      return "Sign-in was cancelled.";
    case "auth/popup-blocked":
      return "Your browser blocked the sign-in window. Allow pop-ups for this site, or try again — we'll redirect you instead.";
    case "auth/account-exists-with-different-credential":
      return "There's already an account with that email, created a different way.";
    case "auth/unauthorized-domain":
      return "This address isn't authorised for sign-in yet. Open the site at its proper domain.";
    case "auth/network-request-failed":
      return "Couldn't reach the server. Check your connection and try again.";
    case "auth/too-many-requests":
      return "Too many attempts. Wait a minute and try again.";
    case "auth/configuration-not-found":
    case "auth/operation-not-allowed":
      return "Google sign-in isn't enabled for this project yet.";
    default:
      return (err && err.message) ? err.message.replace(/^Firebase:\s*/, "") : "Something went wrong.";
  }
}
