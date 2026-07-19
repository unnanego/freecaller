import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";

/**
 * Full account deletion (App Store Guideline 5.1.1(v): an app that creates
 * accounts must let the user delete theirs from inside the app). Wipes
 * everything tied to the signed-in user and removes their Firebase Auth
 * record, so nothing can be recovered:
 *   - their `users/{uid}` doc and its `devices` / `private` subcollections
 *   - the `loginCodes/{code}` lookup for their reusable code
 *   - any unused `activationCodes` that still point at them
 *   - their uid from every other user's `contacts` list
 *   - call history where they were the caller or callee
 *   - the Firebase Auth user itself
 *
 * Runs entirely with the Admin SDK (bypasses security rules) and is triggered
 * by the user tapping "Delete account" in Settings, so no manual step or
 * customer-service round-trip is required.
 */
export const deleteAccount = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign-in required");

  const db = getFirestore();
  const userRef = db.collection("users").doc(uid);

  // 1. The reusable login code lookup (read the code off the private doc first).
  const creds = await userRef.collection("private").doc("creds").get();
  const loginCode = creds.data()?.loginCode as string | undefined;
  if (loginCode) {
    await db.collection("loginCodes").doc(loginCode).delete().catch(() => {});
  }

  // 2. Subcollections under the user doc (devices + private).
  for (const sub of ["devices", "private"]) {
    const docs = await userRef.collection(sub).get();
    await Promise.all(docs.docs.map((d) => d.ref.delete()));
  }

  // 3. Unused invite/activation codes minted for this account.
  const codes = await db.collection("activationCodes").where("uid", "==", uid).get();
  await Promise.all(codes.docs.map((d) => d.ref.delete()));

  // 4. Drop this uid from everyone else's contact list (roster is tiny).
  const users = await db.collection("users").get();
  await Promise.all(
    users.docs
      .filter((u) => u.id !== uid && (u.data().contacts as string[] | undefined)?.includes(uid))
      .map((u) => u.ref.update({ contacts: FieldValue.arrayRemove(uid) }))
  );

  // 5. Call history where this user took part.
  const [outgoing, incoming] = await Promise.all([
    db.collection("calls").where("callerId", "==", uid).get(),
    db.collection("calls").where("calleeId", "==", uid).get(),
  ]);
  await Promise.all([...outgoing.docs, ...incoming.docs].map((d) => d.ref.delete()));

  // 6. The user profile doc, then the Auth record.
  await userRef.delete();
  await getAuth().deleteUser(uid);

  logger.info(`account deleted: ${uid}`);
  return { ok: true };
});
