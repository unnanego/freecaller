// Read what a phone reported about itself, newest first.
//
// This is the other half of lib/data/diagnostics_repo.dart, and it exists for
// one reason: the phone with the Android audio-route bugs belongs to the primary
// user, in another country, updated only through Play and never on a cable. Its
// logcat is unreachable, so the app posts its route report to the server and
// this reads it back.
//
//   ssh -N -L 8090:127.0.0.1:8090 root@<server>     # PocketBase is loopback-only
//   export PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=…
//
//   node tools/diagnostics.mjs                  # last 30, everyone
//   node tools/diagnostics.mjs 100              # last 100
//   node tools/diagnostics.mjs 100 <who>        # …from one person only
//
// <who> is an email, phone, display name or record id.
//
// What a healthy Android voice call looks like — one line per route CHANGE, so
// pressing the speaker button is what produces the second one:
//
//   audioRoute  speaker=false | native: HONOR … want=earpiece | before: … | after: …
//   audioRoute  speaker=true  | native: … telecom setAudioRoute(speaker) … | after: … routed=[speaker]
//
// The `after:` state is the answer to "did the phone do as it was told". A
// `staleNativeCall` line means a previous call was never ended — the bug that
// left the whole phone in a call and killed the speaker for every call after it.
import { authenticate, findUser, pb } from './pb.mjs';

const [limitArg, who] = process.argv.slice(2);
const limit = Number(limitArg) || 30;

await authenticate();

let filter;
if (who) {
  const user = await findUser(who);
  if (!user) {
    console.error(`no account matches "${who}"`);
    process.exit(1);
  }
  // userUid is a plain text field, not a relation (a diagnostic outlives the
  // account that filed it), so this is a string match.
  filter = `userUid = '${user.id}'`;
  console.log(`# ${user.displayName || user.email} (${user.id})\n`);
}

const page = await pb('/api/collections/diagnostics/records', {
  query: { perPage: limit, sort: '-created', filter },
});

if (!page.items.length) {
  console.log('nothing reported yet');
  console.log('(the app posts only from Android, and only while signed in)');
  process.exit(0);
}

for (const item of page.items.reverse()) {
  const when = item.created.replace('T', ' ').slice(0, 19);
  const call = item.callId ? item.callId.slice(0, 8) : '--------';
  console.log(`${when}  ${call}  ${item.event.padEnd(15)}  ${item.detail}`);
}

console.log(`\n${page.items.length} of ${page.totalItems} record(s)`);
