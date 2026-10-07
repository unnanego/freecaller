// Dev-only: be an Apple Watch on a call, through the real watch-bridge, with no
// watch.
//
// It speaks the bridge protocol exactly as the watch app does (see
// deploy/watch-bridge/protocol.go) and plays back to the phone whatever the
// phone sends — a loopback. Answer on the phone, talk, and you hear yourself a
// round trip later: that proves the whole server half of watch calling (call
// record, push, bridge, LiveKit seat, Opus relay both ways) and lets you hear
// what the bridge adds in delay, before any Swift has run.
//
//   export PB_URL=https://pb.holographica.space      # the default is loopback
//   node tools/fakewatch.mjs <watch-user> <phone-user>            # watch rings the phone
//   node tools/fakewatch.mjs <watch-user> --answer                # wait for a call TO the watch user, answer it
//
//   --bridge=wss://…/bridge/ws   override (default: derived from PB_URL)
//   --seconds=N                  hang up after N seconds connected (default 120)
//   --no-echo                    stay silent instead of looping audio back
//
// Users are an email, phone, display name or record id. Needs Node 22+ (global
// WebSocket). Superuser credentials as for the other tools (tools/pb.mjs) — used
// only to impersonate <watch-user>; every call-related request after that is
// made as that user, exactly as the watch would make it.
import { randomUUID } from 'node:crypto';

import { PB_URL, authToken, authenticate, findUser } from './pb.mjs';

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const hit = args.find((a) => a.startsWith(`--${name}=`));
  return hit === undefined ? fallback : hit.slice(name.length + 3);
};
const positional = args.filter((a) => !a.startsWith('--'));
const answerMode = args.includes('--answer');
const echo = !args.includes('--no-echo');
const talkSeconds = Number(flag('seconds', 120));

if (!positional[0] || (!answerMode && !positional[1])) {
  console.log('usage: fakewatch.mjs <watch-user> <phone-user> | <watch-user> --answer');
  process.exit(1);
}

function defaultBridge() {
  const u = new URL(PB_URL);
  if (u.hostname === '127.0.0.1' || u.hostname === 'localhost') {
    return 'ws://127.0.0.1:8095/bridge/ws';
  }
  return `${u.protocol === 'https:' ? 'wss' : 'ws'}://${u.host}/bridge/ws`;
}
const BRIDGE_URL = flag('bridge', defaultBridge());

const RING_MS = 45_000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- as the user

let userToken = null;

async function asUser(path, { method = 'GET', body } = {}) {
  const res = await fetch(PB_URL + path, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: userToken },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${JSON.stringify(data)}`);
  return data;
}

async function impersonate(uid) {
  const res = await fetch(`${PB_URL}/api/collections/users/impersonate/${uid}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: authToken() },
    body: JSON.stringify({ duration: 3600 }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`impersonate ${uid} -> ${res.status} ${JSON.stringify(body)}`);
  return body.token;
}

const setState = (callId, state, extra = {}) =>
  asUser(`/api/collections/calls/records/${callId}`, {
    method: 'PATCH',
    body: {
      state,
      ...(state === 'accepted' ? { acceptedAt: new Date().toISOString() } : {}),
      ...(['ended', 'declined', 'cancelled', 'missed'].includes(state)
        ? { endedAt: new Date().toISOString() }
        : {}),
      ...extra,
    },
  });

// ---------------------------------------------------------------- the call

await authenticate();
const me = await findUser(positional[0]);
userToken = await impersonate(me.id);
console.log(`watch user: ${me.displayName} (${me.id})`);

let callId;
let outgoing;

if (answerMode) {
  outgoing = false;
  console.log('waiting for a call to ring this user… (ring them from a phone)');
  for (;;) {
    const page = await asUser(
      `/api/collections/calls/records?perPage=1&sort=-created&filter=${encodeURIComponent(
        `calleeId = '${me.id}' && state = 'ringing'`,
      )}`,
    );
    const call = page.items[0];
    if (call && Date.now() - Date.parse(call.created.replace(' ', 'T')) < RING_MS) {
      callId = call.id;
      console.log(`ringing: ${call.callerName} — answering`);
      // answeredOn is what tells the server to stop this user's OTHER devices
      // ringing; a fake id is fine, it only has to differ from theirs.
      await setState(callId, 'accepted', { answeredOn: 'fakewatch' });
      break;
    }
    await sleep(1000);
  }
} else {
  outgoing = true;
  const callee = await findUser(positional[1]);
  callId = randomUUID();
  // Name, number, expiry and state are the server's to decide; it overwrites
  // whatever is sent (pb_hooks/calls.pb.js). Sent anyway because the create
  // rule still checks callerId and state.
  await asUser('/api/collections/calls/records', {
    method: 'POST',
    body: { id: callId, callerId: me.id, calleeId: callee.id, isVideo: false, state: 'ringing' },
  });
  console.log(`ringing ${callee.displayName}… (${callId})`);
}

// ---------------------------------------------------------------- the bridge

let state = outgoing ? 'ringing' : 'accepted';
let connectedAt = 0;
let framesIn = 0;
let framesOut = 0;
let finished = false;

const ws = new WebSocket(BRIDGE_URL);
ws.binaryType = 'arraybuffer';

ws.addEventListener('open', () => {
  console.log(`bridge: connected to ${BRIDGE_URL}`);
  ws.send(JSON.stringify({ type: 'hello', v: 1, token: userToken, callId }));
});

ws.addEventListener('message', (ev) => {
  if (typeof ev.data !== 'string') {
    framesIn++;
    if (echo && ws.readyState === WebSocket.OPEN) {
      // The downlink frame is already in uplink format (same 7-byte header).
      ws.send(ev.data);
      framesOut++;
    }
    return;
  }
  const msg = JSON.parse(ev.data);
  switch (msg.type) {
    case 'ready':
      console.log(`bridge: in the room${msg.resumed ? ' (resumed)' : ''}`);
      break;
    case 'state':
      console.log(`call: ${msg.state}${msg.endedBy ? ` by ${msg.endedBy}` : ''}`);
      state = msg.state;
      if (state === 'accepted' && !connectedAt) connectedAt = Date.now();
      if (['declined', 'cancelled', 'missed', 'ended'].includes(state)) finish(null);
      break;
    case 'peer':
      console.log(`peer ${msg.present ? 'joined' : 'left'}`);
      break;
    case 'error':
      console.log(`bridge error: ${msg.code} — ${msg.message}`);
      finish(null);
      break;
  }
});

ws.addEventListener('close', (ev) => {
  console.log(`bridge: closed (${ev.code}${ev.reason ? ` ${ev.reason}` : ''})`);
  finish(null);
});

const stats = setInterval(() => {
  if (connectedAt) console.log(`audio: ${framesIn} frames in, ${framesOut} looped back`);
}, 5000);

if (answerMode) connectedAt = Date.now();

// The caller owns the ring timeout (as CallEngine does on the phone).
const ringTimer = outgoing
  ? setTimeout(() => {
      if (state === 'ringing') finish('missed');
    }, RING_MS)
  : null;

const talkTimer = setInterval(() => {
  if (connectedAt && Date.now() - connectedAt > talkSeconds * 1000) finish('ended');
}, 1000);

process.on('SIGINT', () => finish(state === 'ringing' ? 'cancelled' : 'ended'));

async function finish(writeState) {
  if (finished) return;
  finished = true;
  clearTimeout(ringTimer);
  clearInterval(talkTimer);
  clearInterval(stats);
  if (writeState) {
    try {
      await setState(callId, writeState, writeState === 'ended' ? { endedBy: me.id } : {});
      console.log(`wrote ${writeState}`);
    } catch (e) {
      console.log(`could not write ${writeState}: ${e.message}`);
    }
  }
  try {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'bye' }));
    ws.close();
  } catch {}
  console.log(`done — ${framesIn} frames received, ${framesOut} looped back`);
  setTimeout(() => process.exit(0), 300);
}
