// Dev-only: delete stale push-token device docs left behind by testing
// (sign-out never removed them). Devices regenerate on next login, so this is
// safe/reversible. Stops phantom ringing from accounts a device no longer uses.
//
//   GOOGLE_APPLICATION_CREDENTIALS="<SA key>" node tools/cleanupDevices.mjs
import admin from 'firebase-admin';

const UIDS = {
  'yAOEDg1vy2aXAvfurYg2v9N8mV93': 'Паша (real)',
  'wHNHrsCfHrTuIT7lJNuhudzSrin1': 'Apple Review 2',
  'vsvDQEQ6AugUJyiShXdDD5Bo8vq2': 'Apple Review 3',
  'S92aG2Ps81YfzcZeTDcsfMwm2Cp2': 'No-Profile test (628913)',
};

admin.initializeApp();
const db = admin.firestore();

for (const [uid, name] of Object.entries(UIDS)) {
  const snap = await db.collection('users').doc(uid).collection('devices').get();
  if (snap.empty) {
    console.log(`- ${name}: no device docs`);
    continue;
  }
  for (const doc of snap.docs) {
    await doc.ref.delete();
    console.log(`- ${name}: deleted devices/${doc.id}`);
  }
}
process.exit(0);
