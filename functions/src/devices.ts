import { getFirestore } from "firebase-admin/firestore";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { logger } from "firebase-functions/v2";

/**
 * A push token must belong to exactly one account. When a device registers its
 * token under an account, remove that same token from every OTHER account —
 * otherwise a device that switched accounts via a new login code (without
 * signing out) keeps ringing for the account it left. The roster is tiny, so a
 * full scan is fine. Deletes here re-trigger this handler with no `after`, so
 * there is no loop.
 */
export const dedupeDeviceToken = onDocumentWritten(
  "users/{uid}/devices/{deviceId}",
  async (event) => {
    const after = event.data?.after?.data();
    if (!after) return; // deletion — nothing to dedupe

    const { uid } = event.params;
    const tokens = new Set<string>();
    if (after.fcmToken) tokens.add(after.fcmToken as string);
    if (after.voipToken) tokens.add(after.voipToken as string);
    if (tokens.size === 0) return;

    const db = getFirestore();
    const users = await db.collection("users").get();
    const deletes: Promise<unknown>[] = [];
    for (const u of users.docs) {
      if (u.id === uid) continue;
      const devices = await u.ref.collection("devices").get();
      for (const d of devices.docs) {
        const data = d.data();
        if (
          (data.fcmToken && tokens.has(data.fcmToken as string)) ||
          (data.voipToken && tokens.has(data.voipToken as string))
        ) {
          logger.info(`dedupe: removing users/${u.id}/devices/${d.id} (token now on ${uid})`);
          deletes.push(d.ref.delete());
        }
      }
    }
    await Promise.all(deletes);
  }
);
