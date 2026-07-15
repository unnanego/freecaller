// Dev-only: a device that switched accounts (via a new login code, without
// signing out) leaves its push token registered under the OLD account, so
// calls to the old account still ring it. This finds this device's current
// tokens (by the login code it's signed in with) and removes those tokens from
// every OTHER account, so only the current account rings it.
//
//   GOOGLE_APPLICATION_CREDENTIALS="<SA key>" node tools/dedupeDeviceForCode.mjs 015777
import admin from 'firebase-admin';

const CODE = process.argv[2] || '015777';

admin.initializeApp();
const db = admin.firestore();

const codeDoc = await db.collection('loginCodes').doc(CODE).get();
if (!codeDoc.exists) {
  console.log(`login code ${CODE} not found`);
  process.exit(1);
}
const uid = codeDoc.data().uid;
console.log(`current account for code ${CODE}: ${uid}`);

// This device's current tokens.
const mine = await db.collection('users').doc(uid).collection('devices').get();
const tokens = new Set();
mine.forEach((d) => {
  if (d.data().fcmToken) tokens.add(d.data().fcmToken);
  if (d.data().voipToken) tokens.add(d.data().voipToken);
});
console.log(`this device has ${tokens.size} token(s) registered`);

// Remove those tokens from every OTHER account (roster is tiny — full scan).
const users = await db.collection('users').get();
let removed = 0;
for (const u of users.docs) {
  if (u.id === uid) continue;
  const devs = await u.ref.collection('devices').get();
  for (const d of devs.docs) {
    const data = d.data();
    if (tokens.has(data.fcmToken) || tokens.has(data.voipToken)) {
      console.log(`stale: users/${u.id}/devices/${d.id} — deleting`);
      await d.ref.delete();
      removed++;
    }
  }
}
console.log(`removed ${removed} stale registration(s)`);
process.exit(0);
