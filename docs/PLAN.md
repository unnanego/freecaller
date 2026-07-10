# Freecaller («Звонилка») — Family VoIP Caller App

## Context

A dead-simple family calling app for a blind, 73-year-old, Russian-only-speaking mother-in-law with an iPhone. Family (5–15 people, mixed iOS/Android) installs the app; calls are app-to-app VoIP audio, contacts are phone numbers. Primary input is Siri in Russian («Позвони Аиде через Звонилку»); the app UI (giant VoiceOver-friendly buttons) is the fallback. Repo: `/Users/pavelabdurakhimov/Documents/dev/Freecaller` (cloned from github.com/unnanego/freecaller, empty).

**Confirmed decisions:** app-to-app VoIP only · **voice or video per call, Google Meet-style** (WebRTC via LiveKit; voice = earpiece with speaker toggle, video = speaker + camera switch + swappable fullscreen/corner feeds; call type rides the call doc and push payload) · she has an iPhone, family mixed · provisioned family roster, no SMS auth · Russian display/Siri name **«Звонилка»** (repo stays Freecaller) · Stage 2 = web client + group calls (planned, not built now).

## Stack (research-validated, July 2026)

| Layer | Choice |
|---|---|
| App | Flutter, one codebase (mobile now, web stage 2) |
| Media | LiveKit Cloud free tier, `livekit_client` ~2.8 (iOS/Android/web; group call = same room, more people) |
| Native call UI | `flutter_callkit_incoming` ~3.1.3 — iOS CallKit (incoming via PushKit, outgoing via CXStartCallAction); Android full-screen CallStyle notification + self-managed ConnectionService |
| Push | iOS: APNs VoIP push (PushKit, direct to APNs, .p8 key, topic `<bundle>.voip`); Android: FCM high-priority data message; both sent from Cloud Functions |
| Backend | Firebase: Firestore (roster + call docs), Cloud Functions TS (LiveKit JWT minting, push dispatch, missed-call sweep), Auth via custom tokens (activation-code redemption) |
| Siri | **SiriKit `INStartCallIntent`** via native Swift Intents extension — NOT App Intents (App Intents cannot background-start CallKit calls, CXError code 6; Apple DTS says use SiriKit). Russian «позвони X через Y» grammar is built into Siri — free in ru-RU. This is how WhatsApp does it. |

Flutter packages (complete list): `firebase_core`, `firebase_auth`, `cloud_firestore`, `cloud_functions`, `firebase_messaging`, `livekit_client`, `flutter_callkit_incoming`, `uuid`, `flutter_localizations`+`intl`. No state-management framework (ChangeNotifier/streams), no codegen.
Functions: `firebase-admin`, `firebase-functions`, `livekit-server-sdk`, `jose` + node http2 for APNs (avoid unmaintained node-apn).

**Prerequisites (not code):** Apple Developer account (VoIP push entitlement, Intents extension, TestFlight); Firebase project on Blaze plan (Cloud Functions require it — usage cost ≈ $0 at this scale); LiveKit Cloud project (free tier); Google Play console for Android distribution. Bundle ID TBD at M0 (placeholder `com.unnanego.freecaller`).

## Repo layout

```
/                       # Flutter app at root; firebase.json, firestore.rules, .github/workflows/ci.yaml
├── lib/
│   ├── main.dart, app.dart            # bootstrap, ru-first MaterialApp
│   ├── data/                          # models, user_repo, call_repo, device_repo (plain classes)
│   ├── services/
│   │   ├── auth_service.dart          # activation code → signInWithCustomToken
│   │   ├── call_engine.dart           # THE call state machine (both directions)
│   │   ├── livekit_service.dart       # room connect/disconnect, audio-only
│   │   ├── push_registrar.dart        # FCM + VoIP token upload
│   │   ├── call_ui/                   # abstract CallUi + callkit impl (web impl = stage 2)
│   │   └── intents/                   # abstract IntentsBridge + iOS MethodChannel impl + noop
│   ├── ui/                            # activation, home (giant buttons), in_call, missed banner
│   └── l10n/                          # app_ru.arb (primary), app_en.arb
├── ios/Runner/AppDelegate.swift       # PushKit + synchronous CallKit report + audio bridge + Siri activity
├── ios/SiriIntents/                   # Intents extension: INStartCallIntentHandling, App Group contact store
├── android/.../AndroidManifest.xml    # call permissions, FGS phoneCall, singleInstance; res/xml/shortcuts.xml
├── functions/src/                     # activation.ts, livekit.ts, calls.ts (push dispatch + sweep), push.ts
├── tools/admin.ts                     # provision users, roster, activation codes (service account)
└── docs/SETUP.md, RUNBOOK.md
```

**Platform seams (stage-2 insurance):** `CallUi` interface (showIncoming/startOutgoing/reportConnected/end + events stream) — one CallKit impl now, web impl later via conditional import. `IntentsBridge` emits outgoing-call requests from Siri and pushes contact snapshots (App Group JSON + `INVocabulary`).

## Firestore model

```
users/{uid}: phone (E.164, unique), displayName ("Аида"), contacts [uid…], isAdmin
users/{uid}/devices/{deviceId}: platform, fcmToken?, voipToken?, updatedAt
calls/{callId}: callerId, calleeId, callerName, state, createdAt, acceptedAt?, endedAt?, endedBy?, ringExpiresAt
  state: ringing → accepted|declined|cancelled|missed; accepted → ended
  callId = UUIDv4 = CallKit uuid = LiveKit room name (one room per call, never reused)
activationCodes/{code}: uid, expiresAt (72h), usedAt   # function-only access
```

Rules: roster readable by any signed-in family member; call docs writable by participants only with legal-transition guards; codes locked to Admin SDK. `mintLiveKitToken({callId})` callable checks membership + state, returns JWT (identity=uid, room=callId, TTL 1h).

## Call flows

**Outgoing** (home-screen tap or Siri): mint callId → `CallUi.startOutgoing` (CXStartCallAction) → create `ringing` doc → connect LiveKit room immediately (caller waits alone; instant audio on accept) → watch doc: accepted→in-call · declined/cancelled/45s-timeout(→write missed)→teardown. Hangup: write `ended`.

**Incoming**: `onCallCreated` function pushes VoIP (iOS) / FCM data (Android) with `{callId, callerName, …}`.
- iOS: AppDelegate reports CallKit **synchronously in Swift** before completion — app may be terminated, Dart not running. Failure = `0xbaadca11` crash + push throttling. VoIP push is used ONLY for new ringing calls; cancel/hangup travel via Firestore listener. Cancelled-before-answer: report then immediately end (Apple rule).
- Android: background isolate → full-screen CallStyle notification.
- Accept: write `accepted` → mint token → join room. iOS: don't enable audio until `audioSessionActivated` event (RTCAudioSession `useManualAudio` + activate/deactivate bridge in AppDelegate — the classic lock-screen-no-audio bug).

**Missed authority:** caller's 45s timer writes `missed`; scheduled `sweepStaleCalls` (1 min) is the fallback for caller crash/offline.

## Siri (the product's main input)

- `ios/SiriIntents` extension: `resolveContacts` matches spoken name against App Group JSON snapshot (lowercase, ё→е, prefix match) → `INPerson(customIdentifier: uid)`; multiple matches → `.disambiguation` (Siri reads options aloud — good for blind user); `handle` → `.continueInApp` → app foregrounds → MethodChannel → `CallEngine.startCall` → CallKit outgoing. Fully hands-free (phone must be unlocked; Face ID makes that invisible).
- `INVocabulary.setVocabularyStrings(.contactName)` re-synced whenever roster changes, so Siri recognizes «Аида».
- `INAlternativeAppNames` (≤3) + `ru.lproj` `CFBundleDisplayName` = «Звонилка».
- iOS 18.2+ **default calling app** support (CallKit + INStartCallIntent qualify) → plain «Позвони Аиде» with no app name. Big win — set it on her phone.
- Android voice: best-effort `shortcuts.xml` CREATE_CALL only (App Actions sunsetting into Gemini App Functions); timeboxed 1 day.

## Accessibility (M6, but designed-in throughout)

Home screen = 1–4 contacts as giant full-row buttons, `Semantics(button, label: 'Позвонить Аиде')`, tap-only (no gestures), high contrast, huge text, all strings Russian. In-call = one giant «Положить трубку». Incoming call uses native UI (already VoiceOver/TalkBack-friendly). Activation is helper-operated (6-digit code typed once by family). Verification includes a full screen-curtain VoiceOver run-through.

## Milestones (each ends device-testable; risky spikes first)

- **M0 Scaffold+infra** (~2-3d): flutter create, functions TS init, Firebase/LiveKit/APNs .p8 setup, docs/SETUP.md, CI (analyze+test+tsc).
- **M1 Auth+roster+tokens** (~3-4d): admin.ts, activation flow end-to-end, repos, push_registrar, rules v1, debug contact list.
- **M2 SPIKE push→native ring, no media** (~3-5d, highest risk): script-triggered pushes prove terminated+locked iPhone rings via CallKit and terminated Android 14/15 shows full-screen ring; accept/decline reach Dart; cancel = report-then-end. **Gate: 0 `0xbaadca11` crashes across 20 pushes in all app states.**
- **M3 1:1 call happy path + lifecycle** (~1-1.5w): CallEngine, onCallCreated, token minting, LiveKit audio, all transitions both directions (iOS↔Android). **Gate: iOS lock-screen answer → two-way audio in <2s** (manual-audio bridge; if plugin events insufficient, decide patch/fork here).
- **M4 Hardening** (~1w): speaker/BT routes, CallKit mute↔LiveKit mic, background continuity, network-flap reconnect, kill-mid-call recovery, Doze/aggressive-OEM (Samsung/Xiaomi), missed-call local notifications.
- **M5 Siri** (~1w): extension target, App Group store, Russian resolveContacts, continueInApp wiring, INVocabulary, alt names, default-calling-app; Android shortcuts.xml (1d timebox).
- **M6 Accessibility home + ru l10n** (~1w): the real UI per spec above; VoiceOver screen-curtain audit.
- **M7 Ops+distribution** (~3-5d): LiveKit usage alert + RUNBOOK escape hatch (free tier hard-caps at 5000 participant-min/mo ≈83 min/day of 1:1 and **fails closed** — escape hatch = self-hosted LiveKit on ~$6 VPS, same client code, only URL/keys change), Play full-screen-intent + FGS declarations, TestFlight + Play internal, re-run push matrix on TestFlight build (**production vs sandbox APNs is a classic silent failure**), family rollout + admin runbook.

## Verification

Real devices only from M2 on (CallKit/PushKit/full-screen-intent don't exist on simulators). Minimum matrix: 1 physical iPhone (current iOS) + 1 physical Android 14+. Key end-to-end checks: push matrix {foreground, background, terminated, terminated+locked} × {iOS, Android}; both call directions with accept/decline/cancel/timeout/both-hangup-orders; lock-screen answer audio; airplane-mode callee → missed at 45s; Siri run on her exact config (ru locale, VoiceOver on, locked phone): «Привет Siri, позвони Аиде в Звонилке» → connected call; after default-calling-app: «Позвони Аиде» works.

## Stage 2 outline (not built now)

- **Web:** `call_ui_web.dart` behind the existing seam (in-page ring overlay + Notification API); Firestore listener on `state == ringing` is the "push" while tab open; same rooms/token endpoint; `livekit_client` supports web.
- **Group calls:** `participants[]` + per-uid responses on the call doc; push fan-out to all; end-of-call authority moves to a LiveKit `room_finished` webhook; home screen gains a «Вся семья» giant button. Rooms and CallKit need no changes. Watch the minute budget (5-person 30-min call = 150 participant-min).

## Monthly cost: $0 
(LiveKit free tier + Firebase Blaze at trivial usage), until usage outgrows the LiveKit cap → $6/mo VPS.
