// Creates a dedicated demo account for App Store / TestFlight review and prints a
// permanent, reusable login code to hand to Apple. Mirrors the server logic in
// functions/src/auth.ts (provisionLoginCode) and invite.ts (user provisioning).
//
// Run from the functions/ directory with admin credentials available, e.g.:
//   GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json \
//     node scripts/createReviewAccount.js
// (or after `gcloud auth application-default login` with the Freecaller project set)
//
// Optional env vars:
//   REVIEW_NAME   display name          (default "Apple Review")
//   REVIEW_PHONE  placeholder E.164     (default "+79999999999"; login doesn't need it)
//   LINK_UID      your own account uid  (links the reviewer as your mutual contact,
//                                        so they have someone to call during review)

const admin = require("firebase-admin");
const { randomInt } = require("node:crypto");

const DISPLAY_NAME = process.env.REVIEW_NAME || "Apple Review";
const PHONE = process.env.REVIEW_PHONE || "+79999999999";
const LINK_UID = process.env.LINK_UID;

admin.initializeApp();
const db = admin.firestore();
const auth = admin.auth();
const { Timestamp, FieldValue } = admin.firestore;

async function provisionLoginCode(uid) {
  const credsRef = db.doc(`users/${uid}/private/creds`);
  const existing = (await credsRef.get()).data()?.loginCode;
  if (existing) return existing;
  for (let i = 0; i < 10; i++) {
    const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    const ref = db.collection("loginCodes").doc(code);
    if ((await ref.get()).exists) continue;
    await ref.set({ uid, createdAt: Timestamp.now() });
    await credsRef.set({ loginCode: code }, { merge: true });
    return code;
  }
  throw new Error("Could not mint a unique login code");
}

(async () => {
  const user = await auth.createUser({ displayName: DISPLAY_NAME });
  const uid = user.uid;
  await db.collection("users").doc(uid).set({
    phone: PHONE,
    displayName: DISPLAY_NAME,
    contacts: [],
    isAdmin: false,
    createdAt: Timestamp.now(),
  });

  if (LINK_UID) {
    await Promise.all([
      db.collection("users").doc(uid).update({ contacts: FieldValue.arrayUnion(LINK_UID) }),
      db.collection("users").doc(LINK_UID).update({ contacts: FieldValue.arrayUnion(uid) }),
    ]);
  }

  const code = await provisionLoginCode(uid);
  console.log("\n=== Review demo account created ===");
  console.log("displayName :", DISPLAY_NAME);
  console.log("uid         :", uid);
  console.log("LOGIN CODE  :", code, "  <-- give this to Apple");
  console.log("===================================\n");
  process.exit(0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
