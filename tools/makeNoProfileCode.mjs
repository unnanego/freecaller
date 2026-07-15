// Dev-only: create an auth user + reusable login code but NO users/{uid}
// profile doc. Signing in with the code succeeds, then the app's bootstrap
// profile read returns null → the retry screen shows immediately. Lets you
// verify the "couldn't load / retry" screen deterministically (no network
// timing needed). Delete the printed uid afterwards.
//
//   GOOGLE_APPLICATION_CREDENTIALS="<SA key>" node tools/makeNoProfileCode.mjs
import { randomInt } from 'node:crypto';
import admin from 'firebase-admin';

admin.initializeApp();
const db = admin.firestore();
const auth = admin.auth();

const user = await auth.createUser({ displayName: 'No Profile Test' });
const uid = user.uid;

let code;
for (let i = 0; i < 10; i++) {
  const c = String(randomInt(0, 1_000_000)).padStart(6, '0');
  const ref = db.collection('loginCodes').doc(c);
  if ((await ref.get()).exists) continue;
  await ref.set({ uid, createdAt: admin.firestore.Timestamp.now() });
  await db.doc(`users/${uid}/private/creds`).set({ loginCode: c }, { merge: true });
  code = c;
  break;
}
// NOTE: intentionally NO users/{uid} profile doc.
console.log('NO-PROFILE test uid:', uid);
console.log('LOGIN CODE       :', code, ' <- sign in with this to force the retry screen');
process.exit(0);
