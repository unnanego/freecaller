// Dev-only: end any live (ringing/accepted) call to the callee, as if the
// remote hung up — the callee's engine sees state=ended and tears down.
//
//   GOOGLE_APPLICATION_CREDENTIALS="<SA key>" node tools/endcall.mjs
import admin from 'firebase-admin';

const CALLEE_ID = 'yAOEDg1vy2aXAvfurYg2v9N8mV93'; // Паша (iPhone)

admin.initializeApp();
const db = admin.firestore();

const snap = await db
  .collection('calls')
  .where('calleeId', '==', CALLEE_ID)
  .where('state', 'in', ['ringing', 'accepted'])
  .get();

if (snap.empty) {
  console.log('No live calls to end.');
} else {
  for (const doc of snap.docs) {
    await doc.ref.update({
      state: 'ended',
      endedAt: admin.firestore.Timestamp.now(),
    });
    console.log(`Ended call ${doc.id}`);
  }
}
process.exit(0);
