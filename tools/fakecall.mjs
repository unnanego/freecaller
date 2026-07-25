// Dev-only: drop a `ringing` call record so a target device actually rings,
// for previewing the in-call UI without a second live participant. The
// pb_hooks/calls.pb.js create hook sends the VoIP/FCM push; answering connects
// the callee alone to the LiveKit room.
//
//   ssh -N -L 8090:127.0.0.1:8090 root@<server>
//   export PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=…
//   node tools/fakecall.mjs <callee> [caller] [voice|video]
//
// <callee>/<caller> are an email, phone, display name or record id. The caller
// defaults to any other roster member — the call only needs a plausible name to
// show on the ring screen.
import { randomUUID } from 'node:crypto';

import { authenticate, findUser, listUsers, pb } from './pb.mjs';

const args = process.argv.slice(2);
const calleeArg = args[0];
if (!calleeArg) {
  console.log('usage: fakecall.mjs <callee> [caller] [voice|video]');
  process.exit(1);
}
const isVideo = args.includes('video');
const callerArg = args.slice(1).find((a) => a !== 'voice' && a !== 'video');

await authenticate();

const callee = await findUser(calleeArg);
const caller = callerArg
  ? await findUser(callerArg)
  : (await listUsers()).find((u) => u.id !== callee.id);

if (!caller) {
  console.log('no other user on the roster to call from — pass one explicitly');
  process.exit(1);
}

const callId = randomUUID();
// Long ring window: this is for looking at the UI, not for testing the timeout.
const ringExpiresAt = new Date(Date.now() + 180_000).toISOString();

await pb('/api/collections/calls/records', {
  method: 'POST',
  body: {
    id: callId,
    callerId: caller.id,
    calleeId: callee.id,
    callerName: caller.displayName,
    callerPhone: caller.phone || '',
    isVideo,
    state: 'ringing',
    ringExpiresAt,
  },
});

console.log(
  `Created ${isVideo ? 'VIDEO' : 'VOICE'} call ${callId}: ` +
    `${caller.displayName} -> ${callee.displayName}`,
);
console.log(`End it with: node tools/endcall.mjs ${calleeArg}`);
process.exit(0);
