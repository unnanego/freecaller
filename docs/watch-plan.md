# Apple Watch client

## Why

A phone number lives on one SIM, and with a cellular Apple Watch it's either
the iPhone or the watch that makes ordinary calls, never both. Freecaller calls
go over the internet and don't care about SIMs. So a watch that is a full
Freecaller client works anywhere it has a data connection (Wi-Fi or its own
LTE), with the iPhone at home, switched off, or in another country.

So the watch is a **peer client**: the same account as a second iPhone, ringing
and placing calls on its own. It is not a remote control for the phone.

## The hard constraint: no WebRTC on watchOS

LiveKit's Swift SDK supports iOS, macOS, tvOS and visionOS. **It does not
support watchOS**: its WebRTC framework has no watchOS build. So the watch can't
join a LiveKit room the way the phones do. That decides the architecture:

```
other phone ⇄ LiveKit room ⇄ watch-bridge (Moscow box) ⇄ WSS :443 ⇄ Apple Watch
                                    ⇅
                                PocketBase (signaling, auth, push)
```

`deploy/watch-bridge` is a small Go service. It joins the room **as the watch's
own account**, using a token from the existing `/api/freecaller/livekit-token`
endpoint, and relays audio between the room and a WebSocket from the watch.

- **No transcoding.** The watch encodes Opus, which is what LiveKit already
  carries, so the bridge copies RTP payloads into WebSocket frames and back.
  CPU per call is close to nothing, which matters on a 1-vCPU / 970 MB box.
  That is why it's written in Go (pion, raw RTP access): the Python LiveKit SDK
  only exposes decoded PCM, which would mean transcoding on the server.
- **No credentials on the bridge.** It forwards the watch's PocketBase token.
  The `calls` view rule and the token endpoint decide who joins what, exactly
  as for the phones.
- **Audio only.** The bridge subscribes to audio tracks only and never pulls a
  peer's video.
- **The Flutter app needs no changes.** To the other side the watch is an
  ordinary audio-only participant.
- **Socket and seat are separate.** When the watch's socket drops (on every
  Wi-Fi ↔ LTE handover), the bridge keeps the room seat for 15 s. The watch
  reconnects to the same seat, and the other side hears a short gap instead of
  a dropped call.
- **The socket also carries call state.** watchOS allows sockets only while a
  CallKit call is up (Apple TN3135), and there is no PocketBase realtime in the
  background. So the bridge polls the call record and pushes `state` messages.
  One socket carries everything.

## What exists (branch `apple-watch-client`)

| Piece | Where | Status |
|---|---|---|
| Bridge service | `deploy/watch-bridge/` | Built and unit-tested on Windows (`go test`). The whole session lifecycle runs against a fake PocketBase and a fake room. Cross-compiles to a static Linux binary. **Never run against real LiveKit.** |
| Bridge deploy | `deploy/watch-bridge/deploy.sh`, `watch-bridge.service`, `README.md` | Written, not run |
| Fake watch | `tools/fakewatch.mjs` | Speaks the protocol and loops audio back. Syntax-checked, not run |
| Server: `watchos` devices, `answeredOn` | `pb_migrations/1791400000_watch_client.js` | Parses, not deployed |
| Server: answered-elsewhere cancel push | `pb_hooks/calls.pb.js` | Parses, not deployed |
| Server: watch push topic | `push/push.py` (`apns.watchBundleId`) | Topic routing checked with a stubbed curl |
| iPhone → watch session hand-off | `ios/Runner/WatchSync.swift` (+2 lines in `AppDelegate.swift`, file registered in the Runner target) | **Uncompiled** |
| Watch app | `ios/FreecallerWatch/*.swift` | **Uncompiled.** No Xcode target yet, see setup below |

Everything Swift was written on Windows and has never been through a compiler.
An independent review against Apple's API availability data found no definite
compile errors, as long as the build settings below are used, and its seven
logic bugs are fixed. Still, expect a round of compile fixes.

### Server changes in detail

- `devices.platform` gains `watchos`. APNs refuses a watch token pushed under
  the iPhone app's topic, so the sender has to tell them apart. `push.py` sends
  `watchos` devices the same VoIP payload under `apns.watchBundleId` + `.voip`,
  signed with the same `.p8` key.
- `calls.answeredOn` is the `deviceId` of the device that answered or declined.
  It can be set only by the callee, only in the request that leaves `ringing`,
  and only once. When it's set, the server sends a cancel push to the callee's
  **other** devices, so every other phone, tablet or watch on the account
  stops ringing when one of them answers or declines. The answering device is
  skipped because a cancel push for a call that's up hangs it up. The watch and
  the Flutter app (`CallRepo.setState`) both set it; builds from before it
  don't, and for those nothing changes. A device that misses the push still
  copes: `CallEngine` sees `accepted` and drops its ring (`call_engine.dart`,
  the "another device answered" branch), and its refused `declined` write is
  the case `_teardown` already expects.
- The watch also polls the call record while it rings, as a backstop for a
  lost cancel push.

### The watch app

| File | What |
|---|---|
| `FreecallerWatchApp.swift` | Entry point. PushKit is armed in the app delegate so a background push launch works. |
| `AppSession.swift` | Session from the iPhone over WatchConnectivity, token in the Keychain, `authRefresh` on launch, contacts (phone list ∪ server roster) |
| `PocketBase.swift` | The REST calls: create, patch and get a call, upsert a device, refresh auth, read the roster |
| `CallController.swift` | The state machine: CallKit + PushKit + PocketBase + bridge. Writes the same states with the same ownership as `CallEngine`. |
| `BridgeClient.swift` | One WebSocket per call: hello, control messages, binary audio, ping, uplink backpressure |
| `AudioPipeline.swift` | Mic → 48 kHz → Opus 20 ms → bridge, and bridge → jitter buffer → Opus → speaker. System voice processing provides echo cancellation. Russian 425 Hz ringback and busy tones. |
| `OpusCodec.swift` | Opus via Apple's `AVAudioConverter`. **Whether this exists on watchOS is spike 1.** |
| `JitterBuffer.swift` | Reorders by seq, 60 ms target, skips ahead past 200 ms, treats DTX silence as silence |
| `Views.swift` | Contacts (big buttons, VoiceOver labels), in-call (answer, mute, end, timer), signed-out, Diagnostics (Opus check, push status, echo test, log) |

The iPhone hand-off reads the token from where Dart's `shared_preferences`
already keeps it (`flutter.pbAuth`) and the contacts from the existing Siri sync.
So **no Dart changes** were needed.

## Setup on the MacBook

### 1. Server (from any machine with ssh)

```bash
bash deploy/pocketbase/deploy.sh
```

This ships the migration, hooks and `push.py`. Then, on the server:

1. Add `"watchBundleId": "com.unnanego.freecaller.watchkitapp"` to the `apns`
   block of `/etc/freecaller/push.json`.
2. Add the `/bridge/*` route to the Caddyfile (`deploy/watch-bridge/README.md`).

Then deploy the bridge (needs Go: `brew install go`):

```bash
bash deploy/watch-bridge/deploy.sh
```

### 2. Xcode target

1. Open `ios/Runner.xcworkspace`.
2. **File → New → Target → watchOS → App**. Product name `FreecallerWatch`,
   "Watch App for Existing iOS App" → companion of **Runner**, SwiftUI, no
   tests. **Check that the bundle id comes out as
   `com.unnanego.freecaller.watchkitapp`.** If it doesn't, change either the
   bundle id or `watchBundleId` in `push.json` so the two match.
3. Delete the `ContentView.swift` and `…App.swift` that Xcode generated in the
   new target.
4. Add every file in `ios/FreecallerWatch/` to the watch target only, with
   "Copy items" **unchecked**.
5. Watch target → **General**: deployment target **watchOS 10.0**. Turn on
   "Supports Running Without iOS App Installation", which makes it an
   independent app.
6. Watch target → **Build Settings**. New targets from recent Xcode templates
   default to main-actor isolation, and with those defaults this code does not
   compile (its audio and network classes run off the main thread on purpose).
   Set:
   - Swift Language Version → **Swift 5**
   - Default Actor Isolation → **nonisolated**
     (`SWIFT_DEFAULT_ACTOR_ISOLATION`)
   - Approachable Concurrency → **No** (`SWIFT_APPROACHABLE_CONCURRENCY`)
   - Strict Concurrency Checking → **Minimal**
7. Watch target → **Signing & Capabilities**: team `R9577QC7DM`, add **Push
   Notifications** and **Background Modes → Voice over IP**.
8. Watch target → **Info**: add *Privacy – Microphone Usage Description* =
   «Микрофон нужен, чтобы вас слышали во время звонка». **Without it the app
   crashes** the moment it asks for the microphone. Also check that
   `WKCompanionAppBundleIdentifier` is `com.unnanego.freecaller`. The template
   sets it, and without it the iPhone hand-off never arrives.
9. Build **Runner** for the phone first. `WatchSync.swift` is new code in the
   iPhone app too.

## Test plan, in this order

Each step depends on the one before it. Stop at the first one that fails.

**0. Server path, no watch.**

```bash
PB_URL=https://pb.holographica.space node tools/fakewatch.mjs <watch-account> <your-phone-account>
```

Your phone rings. Answer, talk, and you should hear yourself one round trip
later. That proves the call record, push, bridge, LiveKit seat and Opus relay in
both directions. Then try the other direction: run
`node tools/fakewatch.mjs <watch-account> --answer` and ring that account from
the phone. Check `journalctl -u watch-bridge` and
`systemctl show watch-bridge -p MemoryCurrent` while a call is up.

> Use a **separate account** for the watch while testing (one with no phone
> signed in), so the phone and the watch don't both ring for the same call
> until step 5.

**1. Install and hand-off.** Run the watch target on your watch (Developer Mode
on), then open Звонилка on the iPhone. The watch should leave the
"open Звонилка on iPhone" screen and show your contacts.

**2. Spike 1: Opus and echo.** Open Diagnostics on the watch.
- **Opus** must read «работает». If it reads «нет: …», Apple's Opus isn't on
  watchOS. Plan B is libopus compiled for watchOS behind `OpusEncoder` and
  `OpusDecoder`; nothing else changes. Stop and tell Claude.
- **Тест эха**: talk and read the RTT. Do it on Wi-Fi, then on LTE with the
  iPhone switched off. Listen for your own voice coming back from the wrist
  speaker as an echo, which would mean voice processing isn't cancelling it.
- **Пуш** should read «зарегистрирован».

**3. Spike 2: ringing the watch.** Close the watch app, then ring the watch
account from a phone. It should ring through CallKit even with the app not
running. Answer, talk, and hang up from each side in turn.

**4. Outgoing.** From the watch, call a family phone on Wi-Fi, then on LTE. Try
a no-answer (45 s → «пропущен» on the phone), a decline (busy tone on the watch)
and a hang-up from each side.

**5. Both devices, one account.** Sign the watch into the same account as an
iPhone. Ring it. Answer on the watch, and the iPhone should stop ringing within
a second (the answered-elsewhere push). Then answer on the iPhone, and the watch
should stop within about 2 s (its poll).

**6. Handover.** During a call on the watch, turn its Wi-Fi off. You should see
«Восстанавливаем связь…» and then audio again, and the other side should only
notice a gap.

## Open risks

- **Opus on watchOS**: spike 1, with plan B ready (libopus).
- **Echo on the wrist**: voice processing is documented for watchOS 6+, but how
  well it works with the speaker centimetres from the mic is unknown until
  someone hears it.
- **Latency on LTE**: audio rides TCP, so one lost packet holds up everything
  behind it. The jitter buffer is deliberately small and drops audio rather
  than letting delay build up. The echo-test RTT will show how bad it gets.
- **Server load**: one bridge call should cost a few MB and very little CPU.
  The unit file caps the service at 200 MB so it can never starve PocketBase or
  LiveKit. Measure during step 0.
- **`BRIDGE_ECHO=1`** ships enabled for testing. Set it to 0 in
  `watch-bridge.service` afterwards.

## Later

- Siri on the watch («позвони Аиде») via `INStartCallIntent` in the watch app
- Recents on the watch
- Volume on the Digital Crown during a call
- Sign-in on the watch itself (emailed code), for a watch without an iPhone
