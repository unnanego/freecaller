import { getAuth } from "firebase-admin/auth";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { randomInt } from "node:crypto";

/**
 * A user's permanent, reusable login code. Kept in two places: a function-only
 * `loginCodes/{code}` doc for O(1) lookup at sign-in, and the owner-readable
 * `users/{uid}/private/creds` doc so Settings can show it. Idempotent — returns
 * the existing code if the user already has one.
 */
export async function provisionLoginCode(
  db: FirebaseFirestore.Firestore,
  uid: string
): Promise<string> {
  const credsRef = db.doc(`users/${uid}/private/creds`);
  const existing = (await credsRef.get()).data()?.loginCode as string | undefined;
  if (existing) return existing;

  for (let i = 0; i < 8; i++) {
    const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    const ref = db.collection("loginCodes").doc(code);
    if ((await ref.get()).exists) continue;
    await ref.set({ uid, createdAt: Timestamp.now() });
    await credsRef.set({ loginCode: code }, { merge: true });
    return code;
  }
  throw new HttpsError("internal", "Could not mint a unique login code");
}

/** Ensures the signed-in user has a login code (backfills existing accounts). */
export const ensureLoginCode = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign-in required");
  const code = await provisionLoginCode(getFirestore(), uid);
  return { code };
});

/**
 * The single sign-in entry: accepts either a one-time invite/activation code or
 * a user's permanent login code, and returns a Firebase custom token. Login
 * codes are reusable (re-login on any device); activation codes are consumed.
 */
export const signInWithCode = onCall(async (request) => {
  const code = String(request.data?.code ?? "").trim();
  const deviceId = String(request.data?.deviceId ?? "").trim();
  if (!/^\d{6}$/.test(code)) {
    throw new HttpsError("invalid-argument", "A 6-digit code is required");
  }
  const db = getFirestore();

  // 1. Permanent login code — reusable, never consumed.
  const login = await db.collection("loginCodes").doc(code).get();
  if (login.exists) {
    const uid = login.data()!.uid as string;
    const token = await getAuth().createCustomToken(uid);
    return { token, uid };
  }

  // 2. One-time activation/invite code — mint the token first, then consume.
  const actRef = db.collection("activationCodes").doc(code);
  const act = await actRef.get();
  if (!act.exists) throw new HttpsError("not-found", "Unknown code");
  const data = act.data()!;
  if (data.usedAt) throw new HttpsError("failed-precondition", "Code already used");
  const expiresAt = data.expiresAt as Timestamp | undefined;
  if (!expiresAt || expiresAt.toMillis() < Date.now()) {
    throw new HttpsError("failed-precondition", "Code expired");
  }
  const uid = data.uid as string;
  const token = await getAuth().createCustomToken(uid);
  await db.runTransaction(async (tx) => {
    if ((await tx.get(actRef)).data()?.usedAt) {
      throw new HttpsError("failed-precondition", "Code already used");
    }
    tx.update(actRef, { usedAt: Timestamp.now(), deviceId });
  });
  // Give them a permanent login code so they can get back in next time.
  await provisionLoginCode(db, uid);
  return { token, uid };
});
