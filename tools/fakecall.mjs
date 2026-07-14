// Dev-only: drop a `ringing` call doc so a target device rings, for previewing
// the in-call UI without a second live participant. onCallCreated sends the
// VoIP/FCM push; answering connects the callee alone to the LiveKit room.
//
//   GOOGLE_APPLICATION_CREDENTIALS="<SA key>" node tools/fakecall.mjs [voice|video]
//
// Caller = Оля, Callee = Паша (iPhone). Edit the uids below to retarget.
import { randomUUID } from 'node:crypto';
import admin from 'firebase-admin';

const CALLER_ID = '4oU7yJfkcNRVVOxwSCsjsoGkMe02'; // Оля
const CALLER_NAME = 'Оля';
const CALLER_PHONE = '+70000000000';
const CALLEE_ID = 'yAOEDg1vy2aXAvfurYg2v9N8mV93'; // Паша (iPhone)

const isVideo = (process.argv[2] || 'voice') === 'video';

admin.initializeApp();
const db = admin.firestore();

const callId = randomUUID();
const now = admin.firestore.Timestamp.now();
const ringExpiresAt = admin.firestore.Timestamp.fromMillis(
  now.toMillis() + 180_000,
);

await db.collection('calls').doc(callId).set({
  callerId: CALLER_ID,
  calleeId: CALLEE_ID,
  callerName: CALLER_NAME,
  callerPhone: CALLER_PHONE,
  isVideo,
  state: 'ringing',
  createdAt: now,
  ringExpiresAt,
});

console.log(`Created ${isVideo ? 'VIDEO' : 'VOICE'} call ${callId} -> ${CALLEE_ID}`);
process.exit(0);
