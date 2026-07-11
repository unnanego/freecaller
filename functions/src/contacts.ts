import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { parsePhoneNumberFromString } from "libphonenumber-js";

/** Default region for parsing bare local numbers (e.g. "8 916…" → +7916…). */
const DEFAULT_REGION = "RU";

/** Normalize any raw number to E.164, or null if it isn't a valid number. */
function toE164(raw: string): string | null {
  if (!raw) return null;
  const parsed = parsePhoneNumberFromString(raw, DEFAULT_REGION);
  return parsed && parsed.isValid() ? parsed.number : null;
}

/**
 * WhatsApp/Telegram-style contact discovery: given the phone numbers from the
 * caller's address book, return which of them belong to registered Freecaller
 * users (excluding the caller). The roster is a small family, so scanning all
 * users and normalizing server-side is both cheap and robust to whatever format
 * the admin tool stored the number in.
 */
export const matchContacts = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign-in required");
  }

  const raw = request.data?.phones;
  if (!Array.isArray(raw)) {
    throw new HttpsError("invalid-argument", "phones must be an array");
  }
  // Cap input so a huge address book can't blow up the request.
  const wanted = new Set<string>();
  for (const p of raw.slice(0, 2000)) {
    const e164 = toE164(String(p ?? ""));
    if (e164) wanted.add(e164);
  }
  if (wanted.size === 0) return { matches: [] };

  const db = getFirestore();
  const snap = await db.collection("users").get();

  const matches: { uid: string; displayName: string; phone: string }[] = [];
  for (const doc of snap.docs) {
    if (doc.id === uid) continue; // never surface yourself
    const e164 = toE164(String(doc.data().phone ?? ""));
    if (e164 && wanted.has(e164)) {
      matches.push({
        uid: doc.id,
        displayName: String(doc.data().displayName ?? ""),
        phone: e164,
      });
    }
  }
  return { matches };
});
