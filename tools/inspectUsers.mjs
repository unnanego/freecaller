// Read-only: dump every user's phone, push-device registration, and contact
// count — to diagnose discovery (phone format) and ring (push token) issues.
//
//   GOOGLE_APPLICATION_CREDENTIALS="<SA key>" node tools/inspectUsers.mjs
import admin from 'firebase-admin';

admin.initializeApp();
const db = admin.firestore();

const users = await db.collection('users').get();
for (const u of users.docs) {
  const d = u.data();
  const devs = await u.ref.collection('devices').get();
  const devInfo =
    devs.docs
      .map((dd) => {
        const x = dd.data();
        const toks = [x.fcmToken ? 'fcm' : '', x.voipToken ? 'voip' : '']
          .filter(Boolean)
          .join('+');
        return `${x.platform || '?'}(${toks || 'no-token'})`;
      })
      .join(', ') || 'NONE';
  console.log(
    `${(d.displayName || '?').padEnd(16)} | ${(d.phone || '?').padEnd(16)} | ${u.id} | devices=[${devInfo}] | contacts=${(d.contacts || []).length}`,
  );
}
process.exit(0);
