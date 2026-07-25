# Freecaller — «Звонилка»

Dead-simple family VoIP calling app, built for a blind, Russian-speaking
73-year-old and her family. One tap (or one Siri phrase) — one call.

Calls are WebRTC (via LiveKit), Google-Meet style: pick **voice** (with an
earpiece/speaker toggle) or **video** (front/back camera switch, tap the
corner feed to swap which video is full screen).

- **Voice-first**: «Привет Siri, позвони Аиде через Звонилку» — SiriKit
  calling domain, Russian grammar built in. With «Звонилка» set as the
  iOS default calling app: just «Позвони Аиде».
- **Native call UX**: CallKit on iOS, full-screen CallStyle ring on
  Android; incoming calls work from a locked, terminated phone.
- **Accessible by design**: the home screen is 1–4 giant contact buttons,
  full VoiceOver/TalkBack semantics, everything in Russian.
- **Zero-friction auth**: no SMS, no passwords — the family admin
  provisions the account, and a one-time code is emailed at sign-in.

## Stack

Flutter + self-hosted LiveKit (open-source WebRTC SFU + TURN, media) +
self-hosted PocketBase (auth, roster, call signaling, room tokens, push
fan-out) + `flutter_callkit_incoming`. APNs VoIP push (PushKit) on iOS,
FCM high-priority data on Android — Google's only remaining role, because
waking an Android phone needs it. All your own infra.

## Repo map

| Path | What |
|---|---|
| `lib/` | Flutter app (services/call_engine.dart is the call state machine) |
| `ios/Runner/AppDelegate.swift` | PushKit→CallKit synchronous report, WebRTC audio-session bridge, Siri handoff |
| `ios/SiriIntents/` | SiriKit Intents extension (INStartCallIntent) |
| `deploy/pocketbase/` | Backend: schema migrations, hooks (call state machine, LiveKit tokens, push fan-out, contacts), APNs/FCM senders |
| `tools/admin.mjs` | Family roster provisioning CLI |
| `deploy/livekit/` | Self-hosted LiveKit media server (Docker Compose) |
| `docs/SETUP.md` | One-time infra setup (LiveKit, APNs, Xcode targets) |
| `docs/RUNBOOK.md` | Ops: LiveKit cap, push debugging, roster changes |

## Stage 2 (planned)

Web client (same LiveKit rooms, in-page ring UI behind the existing
`CallUi` seam) and group calls (multi-participant rooms + push fan-out).
