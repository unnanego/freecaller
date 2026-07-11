import { getAuth } from "firebase-admin/auth";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";

/**
 * Redeems a one-time 6-digit activation code (provisioned by the admin tool)
 * for a Firebase custom auth token. This is the only sign-in path in the app:
 * no SMS, no passwords — a helper types the code once on the new device.
 */
export const redeemActivationCode = onCall(async (request) => {
  const code = String(request.data?.code ?? "").trim();
  const deviceId = String(request.data?.deviceId ?? "").trim();
  if (!/^\d{6}$/.test(code) || !deviceId) {
    throw new HttpsError("invalid-argument", "code (6 digits) and deviceId are required");
  }

  const db = getFirestore();
  const codeRef = db.collection("activationCodes").doc(code);

  // Verify the code, but don't consume it yet.
  const snap = await codeRef.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Unknown activation code");
  }
  const data = snap.data()!;
  if (data.usedAt) {
    throw new HttpsError("failed-precondition", "Code already used");
  }
  const expiresAt = data.expiresAt as Timestamp | undefined;
  if (!expiresAt || expiresAt.toMillis() < Date.now()) {
    throw new HttpsError("failed-precondition", "Code expired");
  }
  const uid = data.uid as string;

  // Mint the token FIRST — if this fails, the code stays unused.
  const token = await getAuth().createCustomToken(uid);

  // Only now consume the code, atomically guarding against a concurrent redeem.
  await db.runTransaction(async (tx) => {
    const fresh = await tx.get(codeRef);
    if (fresh.data()?.usedAt) {
      throw new HttpsError("failed-precondition", "Code already used");
    }
    tx.update(codeRef, { usedAt: Timestamp.now(), deviceId });
  });

  return { token, uid };
});
