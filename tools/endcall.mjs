// Dev-only: end any live (ringing/accepted) call to a callee, as if the remote
// hung up — their engine sees state=ended and tears down.
//
//   ssh -N -L 8090:127.0.0.1:8090 root@<server>
//   export PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=…
//   node tools/endcall.mjs <callee>
//
// <callee> is an email, phone, display name or record id.
import { authenticate, findUser, pb } from './pb.mjs';

const [calleeArg] = process.argv.slice(2);
if (!calleeArg) {
  console.log('usage: endcall.mjs <callee>');
  process.exit(1);
}

await authenticate();

const callee = await findUser(calleeArg);
const page = await pb('/api/collections/calls/records', {
  query: {
    filter: `calleeId = '${callee.id}' && (state = 'ringing' || state = 'accepted')`,
    perPage: '50',
  },
});

if (page.items.length === 0) {
  console.log('No live calls to end.');
}

for (const call of page.items) {
  // `ringing -> ended` is not a legal transition (pb_hooks/calls.pb.js), so a
  // call that never got answered ends the way a real one does: cancelled.
  const state = call.state === 'accepted' ? 'ended' : 'cancelled';
  await pb(`/api/collections/calls/records/${call.id}`, {
    method: 'PATCH',
    body: { state, endedAt: new Date().toISOString() },
  });
  console.log(`Ended call ${call.id} (${call.state} -> ${state})`);
}

process.exit(0);
