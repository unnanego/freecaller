# End-to-end encrypted calls

## Where things stand

Every call is encrypted **in transit** and readable **on our server**:

| Hop | Encrypted? | Who can read the media |
|---|---|---|
| Phone ⇄ LiveKit (WebRTC, DTLS-SRTP) | yes | the endpoints, and the SFU |
| Through coturn (TURN relay) | yes, relayed as-is | nobody: coturn never has the keys |
| Signaling, tokens, PocketBase (TLS) | yes | the endpoints, and the server |
| Watch ⇄ watch-bridge (`wss://`) | yes | the watch, and the bridge |
| **Inside the Moscow box** (LiveKit, watch-bridge) | **no** | anyone with root on it |

An SFU decrypts each sender's SRTP and re-encrypts it for each receiver. So
anyone who controls the box can record calls: an intruder, a hoster, or
whoever takes the machine. Nothing records today, but nothing prevents it
either. The app never turns on LiveKit's end-to-end encryption (nothing in
`lib/` touches `E2EEOptions`).

## What E2EE changes

LiveKit E2EE encrypts each audio and video *frame* on the sender, with a key the
server never sees, before the frame goes into SRTP. The SFU still routes the
frames but sees only ciphertext. The receiver decrypts after SRTP. The Flutter
SDK (`livekit_client` 2.10, through flutter_webrtc's native `FrameCryptor`)
supports it on iOS and Android:

```dart
final keyProvider = await BaseKeyProvider.create();
await keyProvider.setSharedKey(callKey);          // one key per call
final room = Room(roomOptions: RoomOptions(e2eeOptions: E2EEOptions(keyProvider: keyProvider)));
```

That part is small. **The real work is getting the call key to the other side
without the server seeing it**, because every channel we have (the call record,
pushes, LiveKit data messages) goes through the server.

## Design

### Key exchange: one keypair per device, one key per call

1. **Each install makes an X25519 keypair** on first launch. The private key
   stays in the Keychain on iOS or the Keystore-backed secure storage on
   Android, and never leaves the device. The public key goes into that
   install's `devices` record (new field `publicKey`). The watch does the same
   with CryptoKit.
2. **The caller makes a random 32-byte call key** for each call.
3. **The caller wraps that key for each of the callee's devices.** For each one:
   - make a fresh ephemeral X25519 key and run ECDH with the device's public key;
   - derive a wrapping key from that with HKDF-SHA256 (call id as context);
   - encrypt the call key with AES-GCM.

   The results go into the call record as `keys: {deviceId: blob}` when it is
   created. This is what libsodium calls a "sealed box", or HPKE base mode.
4. **The answering device unwraps its own blob**, and both sides join the room
   with the call key.

The server stores and forwards blobs it can't open. Every library needed exists
on every platform: CryptoKit on iOS and watchOS, and the `cryptography` package
in Dart (X25519, HKDF and AES-GCM, pure Dart and audited, no native code).

Multi-device needs nothing extra: every callee device gets its own blob, and
whichever one answers (`answeredOn`) can join.

### Server

- Migration: `devices.publicKey` (text) and `calls.keys` (JSON).
- `calls.pb.js`: `keys` can be set only when the call is created, and only by
  the caller. It becomes immutable after that, like `callerName`.
- `devices`: the owner may change `publicKey`. That is the same rule as for
  tokens, and the existing owner pinning covers it.
- Ring pushes stay as they are. The key never goes into a push; the callee
  reads it from the call record once it has answered, which it already does.

### Rollout and older builds

A room can't mix encrypted and plain participants: one side would hear
static. So:

- The caller encrypts **only if every one of the callee's devices has a
  `publicKey`**. Otherwise the call goes ahead unencrypted, exactly as today.
  The call record says which (`e2ee: true/false`), and the callee follows it.
- As soon as every family device runs a build with keys, every call is
  encrypted. Later, a build can refuse plain calls outright, once nobody is
  left on an old version.
- The in-call screen can show a small lock when the call is encrypted (spoken
  to VoiceOver), so it is visible rather than assumed.

### The watch

The bridge stays as it is, a relay of opaque Opus packets, which suits E2EE.
The watch has to do LiveKit's frame encryption itself in Swift, matching the
phones byte for byte:

- **Frame layout:** to be confirmed against `frame_crypto_transformer.cc` in
  webrtc-sdk before writing any of this. From memory, it is:
  - N unencrypted header bytes (1 for Opus), which also serve as the AES-GCM
    additional data;
  - then the AES-GCM ciphertext with its 16-byte tag;
  - then the 12-byte IV;
  - then a 2-byte trailer: IV length and key index.
- **Key:** LiveKit stretches the shared key into the AES key (PBKDF2-SHA256
  with the salt `LKFrameEncryptionKey`). CommonCrypto's `CCKeyDerivationPBKDF`
  is on watchOS. The exact parameters also need confirming from the source.
- **IV:** the receiver reads the IV from the trailer, so the watch only has to
  make its IVs unique (a counter plus the SSRC, or random).

Two things on the bridge need checking:

- It reads Opus durations from the TOC byte. With E2EE, that byte is still the
  unencrypted first byte, if the 1-byte header holds. If it doesn't, the watch
  sends the duration in the frame header instead.
- Its `redPrimary` path goes unused: the SDK turns RED off whenever E2EE is on
  (`disableRed: room.e2eeManager != null` in `local.dart`).

A test vector settles the format before any device is involved. The Flutter
app encrypts one frame with a known key and saves it; a Swift unit test has to
decrypt it.

## Costs and trade-offs

- **No more RED on audio.** RED is the redundancy LiveKit adds against packet
  loss, and the SDK disables it under E2EE. That matters for the throttled
  Russian callees. Opus's own in-band FEC still works, because it lives inside
  the encrypted payload. Measure call quality on a bad network before making
  E2EE the default.
- **CPU and battery:** AES-GCM on every frame is cheap for audio, and
  noticeable but fine for 720p video on any phone from the last ~6 years.
  Hardware AES is everywhere.
- **Debugging:** the server can no longer look inside the media. LiveKit's
  packet statistics still work; what's in the audio and video can't be seen.
- **The limit, stated plainly:** this protects against a server that is
  *read*: seized, logged, or someone with root listening in. It does not
  protect against a server that is *actively rewritten* to hand out fake public
  keys before a call (a man-in-the-middle). Stopping that takes key
  verification: comparing safety numbers, or a warning when a contact's key
  changes. That is a poor fit for a blind primary user, and a reinstall changes
  keys anyway. Worth stating in the privacy policy as "end-to-end encrypted;
  keys are not verified".

## Phases

1. **Phone ⇄ phone** (Dart + server). Keypairs, the `publicKey` and `keys`
   fields, wrap and unwrap, `E2EEOptions`, the fallback to plain calls, the
   lock icon. Test on two phones, then on a bad network (RED off).
2. **Rollout.** Ship it. Once every family device has a key, every call is
   encrypted.
3. **Watch.** Keypair, unwrap, and Swift frame encryption checked against the
   test vector; bridge adjustments if the TOC byte turns out to be encrypted.
   Until this lands, a callee with a watch gets plain calls (by the rule above,
   because the watch has no key). That is the honest fallback. The alternative
   is to leave the watch out of the key wrap and let it miss encrypted calls.
4. **Later, optional:** a warning when a contact's key changes, and dropping
   plain calls entirely.

## Open questions

- Should the watch hold calls back from E2EE until phase 3 (plain calls for
  anyone wearing one), or miss encrypted calls until then? Recommended: hold
  them back, since a missed call is worse than one that isn't end-to-end
  encrypted.
- Should video be end-to-end encrypted too, or only audio? Recommended: both.
  It is the same switch, and video is the more sensitive of the two.
