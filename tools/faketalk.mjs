// Dev-only: ring a device AND talk to it, with no second phone in the room.
//
// tools/fakecall.mjs only creates the call record, so answering it connects you
// to an empty room — enough to look at the in-call UI, useless for hearing
// anything. This joins the room as the caller and publishes a WAV, so answering
// produces real audio out of the earpiece or the speaker. That is the only way
// to test the audio path (route, speaker toggle, CallKit hand-over) on a single
// device.
//
// It also reports whether the phone's OWN audio track arrives, which is the
// other half of a call working.
//
//   export PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=…
//   export PB_URL=https://pb.holographica.space      # the default is loopback
//   node tools/faketalk.mjs <callee> [caller] [options]
//
//   --say="текст"      speak this instead of the default phrase (macOS `say`)
//   --file=path.wav    publish this WAV instead (16-bit PCM; any sample rate)
//   --voice=Milena     `say` voice; Milena is the Russian one
//   --repeat=N         play it N times (default 3)
//   --seconds=N        give up after N seconds if nobody answers (default 120,
//                      though the phone's own ring UI gives up at ~45s and the
//                      call then goes `missed`, which stops this too)
//   video              ring as a video call
//
// <callee>/<caller> are an email, phone, display name or record id.
//
// How it gets into the room: a superuser cannot mint a LiveKit token (the hook
// scopes tokens to the call's two participants), so this impersonates the CALLER
// through PocketBase and then asks the app's own endpoint, exactly as the real
// caller's app would. No LiveKit API secret needed or handled here.
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { PB_URL, authToken, authenticate, findUser, listUsers, pb } from './pb.mjs';

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const hit = args.find((a) => a.startsWith(`--${name}=`));
  return hit === undefined ? fallback : hit.slice(name.length + 3);
};
const positional = args.filter((a) => !a.startsWith('--') && a !== 'voice' && a !== 'video');

const calleeArg = positional[0];
if (!calleeArg) {
  console.log('usage: faketalk.mjs <callee> [caller] [--say=… | --file=…] [video]');
  process.exit(1);
}
const callerArg = positional[1];
const isVideo = args.includes('video');
const repeat = Number(flag('repeat', 3));
const giveUpAfterMs = Number(flag('seconds', 120)) * 1000;

// ---------------------------------------------------------------- the audio

/** A WAV to publish: whatever was asked for, else synthesised speech. */
function resolveWav() {
  const file = flag('file');
  if (file) {
    if (!existsSync(file)) throw new Error(`no such file: ${file}`);
    return { path: file, temporary: false };
  }
  const phrase = flag('say', 'Привет! Это проверка звука. Раз, два, три, четыре, пять.');
  const voice = flag('voice', 'Milena');
  const aiff = join(tmpdir(), `faketalk-${process.pid}.aiff`);
  const wav = join(tmpdir(), `faketalk-${process.pid}.wav`);
  // Both tools ship with macOS, which is where these scripts are run — no
  // ffmpeg, no committed audio asset. 48 kHz mono 16-bit is what LiveKit wants.
  execFileSync('say', ['-v', voice, '-o', aiff, phrase]);
  execFileSync('afconvert', ['-f', 'WAVE', '-d', 'LEI16@48000', '-c', '1', aiff, wav]);
  unlinkSync(aiff);
  return { path: wav, temporary: true };
}

/**
 * Parse a 16-bit PCM WAV by walking its chunks.
 *
 * Not by assuming the data starts at byte 44: afconvert writes a `FLLR` padding
 * chunk before `data`, and reading from a fixed offset would publish the padding
 * as audio — i.e. noise, which is indistinguishable from a routing bug and would
 * send us chasing the wrong thing.
 */
function readPcm(path) {
  const buf = readFileSync(path);
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error(`${path} is not a RIFF/WAVE file`);
  }
  let channels;
  let sampleRate;
  let bits;
  let data;
  let at = 12;
  while (at + 8 <= buf.length) {
    const id = buf.toString('ascii', at, at + 4);
    const size = buf.readUInt32LE(at + 4);
    const body = at + 8;
    if (id === 'fmt ') {
      channels = buf.readUInt16LE(body + 2);
      sampleRate = buf.readUInt32LE(body + 4);
      bits = buf.readUInt16LE(body + 14);
    } else if (id === 'data') {
      data = buf.subarray(body, Math.min(body + size, buf.length));
    }
    at = body + size + (size % 2); // chunks are word-aligned
  }
  if (!data || !sampleRate) throw new Error(`${path}: no fmt/data chunk`);
  if (bits !== 16) throw new Error(`${path}: need 16-bit PCM, got ${bits}-bit`);
  // Copy rather than view the file buffer: an Int16Array view needs 2-byte
  // alignment and the data chunk's offset is not guaranteed to be even.
  const samples = new Int16Array(data.length >> 1);
  for (let i = 0; i < samples.length; i++) samples[i] = data.readInt16LE(i * 2);
  return { samples, sampleRate, channels: channels || 1 };
}

// ---------------------------------------------------------------- PocketBase

/** Ask PocketBase for a user token for [uid] (superuser-only). */
async function impersonate(uid) {
  const res = await fetch(`${PB_URL}/api/collections/users/impersonate/${uid}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: authToken() },
    body: JSON.stringify({ duration: 600 }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`impersonate ${uid} -> ${res.status} ${JSON.stringify(body)}`);
  return body.token;
}

/** The room credentials the caller's own app would get. */
async function livekitToken(userToken, callId) {
  const res = await fetch(`${PB_URL}/api/freecaller/livekit-token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: userToken },
    body: JSON.stringify({ callId }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`livekit-token -> ${res.status} ${JSON.stringify(body)}`);
  return body;
}

async function callState(callId) {
  try {
    const record = await pb(`/api/collections/calls/records/${callId}`);
    return record.state;
  } catch {
    return null; // deleted, or we lost the network — treat as "unknown"
  }
}

// ---------------------------------------------------------------- main

const wav = resolveWav();
const { samples, sampleRate, channels } = readPcm(wav.path);
const seconds = (samples.length / channels / sampleRate).toFixed(1);
console.log(`audio: ${wav.path} — ${sampleRate} Hz, ${channels}ch, ${seconds}s`);

// Imported by name so a machine without the native SDK installed still parses
// this file and reaches the error message rather than a syntax failure.
const { AudioFrame, AudioSource, LocalAudioTrack, Room, RoomEvent, TrackPublishOptions, TrackSource, dispose } =
  await import('@livekit/rtc-node');

// --dry-run stops here: everything above needs no credentials and no network, so
// it is the half worth checking on its own — that the speech synthesis, the WAV
// parsing and the SDK's API surface all still line up.
if (args.includes('--dry-run')) {
  const source = new AudioSource(sampleRate, channels);
  const track = LocalAudioTrack.createAudioTrack('faketalk', source);
  const options = new TrackPublishOptions();
  options.source = TrackSource.SOURCE_MICROPHONE;
  const head = new Int16Array(samples.subarray(0, Math.trunc(sampleRate / 10) * channels));
  await source.captureFrame(
    new AudioFrame(head, sampleRate, channels, Math.trunc(head.length / channels)),
  );
  const loudest = samples.reduce((m, s) => Math.max(m, Math.abs(s)), 0);
  console.log(`dry run OK — track "${track.name}", peak amplitude ${loudest}/32767`);
  await track.close();
  await dispose();
  process.exit(0);
}

await authenticate();

const callee = await findUser(calleeArg);
const caller = callerArg
  ? await findUser(callerArg)
  : (await listUsers()).find((u) => u.id !== callee.id);
if (!caller) throw new Error('no other roster member to call from — pass one explicitly');

const callId = randomUUID();
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
    // Long ring window: this waits for a human to pick up a phone.
    ringExpiresAt: new Date(Date.now() + giveUpAfterMs).toISOString(),
  },
});
console.log(`ringing ${callee.displayName} as ${caller.displayName} — call ${callId}`);

const userToken = await impersonate(caller.id);
const { token, url } = await livekitToken(userToken, callId);
console.log(`joining ${url} as the caller…`);

const room = new Room();
await room.connect(url, token, { autoSubscribe: true, dynacast: false });

const source = new AudioSource(sampleRate, channels);
const track = LocalAudioTrack.createAudioTrack('faketalk', source);
const options = new TrackPublishOptions();
options.source = TrackSource.SOURCE_MICROPHONE;
await room.localParticipant.publishTrack(track, options);
console.log('published — answer the call');

// The other half of "does audio work": their track reaching us. Every bit of
// this is defensive — event names and callback shapes shift between SDK
// versions, and losing the commentary is survivable where losing the audio is
// not. An exception thrown inside an emit would take the process down.
const say = (line) => {
  try {
    console.log(line);
  } catch {}
};
try {
  room.on(RoomEvent.TrackSubscribed, (...a) => {
    try {
      say(`<- receiving ${a[0]?.kind === 2 ? 'video' : 'audio'} from the phone`);
    } catch {}
  });
  room.on(RoomEvent.ParticipantConnected, (p) => say(`<- ${p?.identity ?? 'peer'} joined`));
  room.on(RoomEvent.ParticipantDisconnected, (p) => say(`<- ${p?.identity ?? 'peer'} left`));
  room.on(RoomEvent.Disconnected, () => say('<- room disconnected'));
} catch {}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Push the file through in 20 ms frames, PACED to real time.
 *
 * captureFrame() looks like it applies backpressure and does not: it updates
 * some bookkeeping and hands the frame straight to the native buffer, which is
 * bounded by the queue size given to AudioSource. Feeding a whole 5-second
 * phrase in a tight loop therefore overflows that buffer and everything past its
 * depth is silently discarded — and because waitForPlayout() resolves off its own
 * timer rather than off real playout, the loop comes round and replays the
 * opening again. The audible result is the first fraction of a second stuttering
 * forever, which is what the first version of this did.
 *
 * So the queue is kept shallow on purpose: never more than QUEUE_TARGET_MS of
 * audio ahead of the wall clock. `queuedDuration` decays in real time, so
 * waiting on it IS the pacing.
 */
const FRAME_MS = 20;
const QUEUE_TARGET_MS = 200;
async function play() {
  const perFrame = Math.trunc((sampleRate * FRAME_MS) / 1000) * channels;
  for (let at = 0; at < samples.length; at += perFrame) {
    // A COPY, not a subarray view, and this is not a style choice: AudioFrame
    // .protoInfo() hands the native side `this.data.buffer` — the whole
    // underlying ArrayBuffer — and ignores the view's byteOffset and length. Give
    // it a view into the file and every frame transmits the START of the file
    // instead of this slice of it: the same 20 ms repeated 50 times a second,
    // which is audible as a buzz. `new Int16Array(view)` copies, so byteOffset is
    // 0 and the buffer is exactly one frame long.
    const chunk = new Int16Array(samples.subarray(at, Math.min(at + perFrame, samples.length)));
    while (source.queuedDuration > QUEUE_TARGET_MS) await sleep(FRAME_MS);
    await source.captureFrame(
      new AudioFrame(chunk, sampleRate, channels, Math.trunc(chunk.length / channels)),
    );
  }
  await source.waitForPlayout();
  // Let the tail actually leave the buffer, and leave a beat between repeats so
  // the phrase does not run into itself.
  await sleep(700);
}

const startedAt = Date.now();
let played = 0;
let answered = false;
while (played < repeat) {
  const state = await callState(callId);
  if (state && state !== 'ringing' && state !== 'accepted') {
    console.log(`call is ${state} — stopping`);
    break;
  }
  if (state === 'accepted' && !answered) {
    answered = true;
    console.log('answered — playing');
  }
  if (!answered) {
    if (Date.now() - startedAt > giveUpAfterMs) {
      console.log('nobody answered — giving up');
      break;
    }
    await new Promise((r) => setTimeout(r, 1000));
    continue;
  }
  await play();
  played++;
  console.log(`played ${played}/${repeat}`);
}

if (answered) {
  // Leave the call as the app would when the caller hangs up, so the phone's UI
  // closes instead of sitting in a room nobody is in.
  try {
    await pb(`/api/collections/calls/records/${callId}`, {
      method: 'PATCH',
      body: { state: 'ended', endedAt: new Date().toISOString(), endedBy: caller.id },
    });
  } catch (e) {
    console.log(`could not mark the call ended: ${e.message}`);
  }
}

await track.close();
await room.disconnect();
await dispose();
if (wav.temporary) unlinkSync(wav.path);
console.log('done');
process.exit(0);
