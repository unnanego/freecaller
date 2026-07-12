import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { parsePhoneNumberFromString } from "libphonenumber-js";
import { randomInt } from "node:crypto";

const DEFAULT_REGION = "RU";

function toE164(raw: string): string | null {
  const parsed = parsePhoneNumberFromString(raw, DEFAULT_REGION);
  return parsed && parsed.isValid() ? parsed.number : null;
}

async function mintCode(
  db: FirebaseFirestore.Firestore,
  uid: string
): Promise<string> {
  for (let i = 0; i < 5; i++) {
    const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    const ref = db.collection("activationCodes").doc(code);
    if ((await ref.get()).exists) continue;
    await ref.set({
      uid,
      expiresAt: Timestamp.fromMillis(Date.now() + 7 * 24 * 3600 * 1000),
      usedAt: null,
      createdAt: Timestamp.now(),
    });
    return code;
  }
  throw new HttpsError("internal", "Could not mint a unique code");
}

/**
 * Invitation-based registration: a signed-in user invites someone by name +
 * phone. Provisions the invitee (or reuses an existing account with that
 * phone), links the two as mutual contacts, and returns a one-time activation
 * code (valid 7 days) that the inviter shares out-of-band (their own messenger).
 * The invitee redeems it via redeemActivationCode — no SMS provider needed.
 */
export const inviteContact = onCall(async (request) => {
  const inviterUid = request.auth?.uid;
  if (!inviterUid) {
    throw new HttpsError("unauthenticated", "Sign-in required");
  }
  const name = String(request.data?.name ?? "").trim();
  const phone = toE164(String(request.data?.phone ?? "").trim());
  if (!name || !phone) {
    throw new HttpsError("invalid-argument", "A name and a valid phone are required");
  }

  const db = getFirestore();

  // Reuse an existing account with this phone, else provision a new one.
  const existing = await db
    .collection("users")
    .where("phone", "==", phone)
    .limit(1)
    .get();

  let inviteeUid: string;
  if (!existing.empty) {
    inviteeUid = existing.docs[0].id;
  } else {
    const user = await getAuth().createUser({ displayName: name });
    inviteeUid = user.uid;
    await db.collection("users").doc(inviteeUid).set({
      phone,
      displayName: name,
      contacts: [],
      isAdmin: false,
      createdAt: Timestamp.now(),
    });
  }

  if (inviteeUid === inviterUid) {
    throw new HttpsError("failed-precondition", "That's your own number");
  }

  // Link both directions (arrayUnion is idempotent if already linked).
  await Promise.all([
    db.collection("users").doc(inviterUid).update({
      contacts: FieldValue.arrayUnion(inviteeUid),
    }),
    db.collection("users").doc(inviteeUid).update({
      contacts: FieldValue.arrayUnion(inviterUid),
    }),
  ]);

  const code = await mintCode(db, inviteeUid);
  return { code };
});
