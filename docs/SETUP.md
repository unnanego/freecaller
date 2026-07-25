# Freecaller («Звонилка») — Setup

One-time infrastructure setup. Code assumes bundle/application id
`com.unnanego.freecaller` and App Group `group.com.unnanego.freecaller` —
change consistently in `ios/Runner/AppDelegate.swift`,
`ios/SiriIntents/ContactsStore.swift`, entitlements files,
`android/app/build.gradle.kts`, and `res/xml/shortcuts.xml` if needed.

## 1. PocketBase (the backend)

Auth, the roster, call signaling, room tokens and push fan-out all live in
one self-hosted PocketBase. Full recipe — binary, systemd unit, schema
migrations, hooks, the APNs/FCM senders and `verify.sh` — in
[`deploy/pocketbase/`](../deploy/pocketbase/).

Two things that are easy to miss:

- **SMTP.** Sign-in is a one-time code sent by email and nothing else, so a
  mail transport that doesn't work is a total outage — and it fails silently
  (`request-otp` answers 200 either way, so as not to leak who has an
  account). Create a no-reply mailbox at your mail host, then run
  [`deploy/pocketbase/configure-mail.sh`](../deploy/pocketbase/configure-mail.sh)
  on the server: it sets the SMTP credentials, the sender identity and the
  Russian OTP email template, and ends by sending a real test message.
  Send from the host that owns the domain's MX/SPF or the codes land in spam.
- **A public URL.** PocketBase binds to loopback; put it behind a TLS reverse
  proxy (Caddy on the same box already fronts LiveKit). `Config.pbUrl`
  defaults to the production host, so nothing is needed at build time unless
  you point elsewhere: `--dart-define=PB_URL=http://127.0.0.1:8090`.

## 1b. Firebase (FCM only)

Google is still how an Android phone gets woken for a call, and nothing
else. Create a Firebase project, then
`dart pub global activate flutterfire_cli && flutterfire configure` — it
registers the iOS + Android apps, writes `lib/firebase_options.dart` and
downloads `android/app/google-services.json` and
`ios/Runner/GoogleService-Info.plist`. Put the project's service-account
JSON on the PocketBase host for `push.py` (see
`deploy/pocketbase/push/push.json.example`). iOS never touches FCM — it is
woken by PushKit.

## 2. LiveKit (self-hosted media server)

The media/SFU + TURN server runs on your own VPS. Full recipe (Docker
Compose, domain, firewall) in [`deploy/livekit/README.md`](../deploy/livekit/README.md).
In short: stand up the server, generate an API key/secret, then:

Put the key, secret and URL in `/etc/freecaller/livekit.json` on the
PocketBase host (template: `deploy/pocketbase/livekit/livekit.json.example`);
`livekit_token.py` mints the per-participant room tokens from there.

No app code changes — `livekit_client` and the token endpoint talk to any
LiveKit server. (LiveKit Cloud's managed free tier is a drop-in alternative
if you ever want it: same three values, `wss://<project>.livekit.cloud`.)

## 3. APNs VoIP push (iOS incoming calls)

1. Apple Developer portal → Keys → new key with **Apple Push Notifications
   service** enabled → download the `.p8`.
2. Put the `.p8` on the PocketBase host and point
   `/etc/freecaller/push.json` at it (`apns.key_id`, `apns.team_id`,
   `apns.bundle_id`, `apns.env`). Template:
   `deploy/pocketbase/push/push.json.example`. **Switch `apns.env` to
   `production` for TestFlight/App Store builds** — a sandbox/production
   mismatch silently drops pushes.

## 4. Xcode (one-time project surgery)

Open `ios/Runner.xcworkspace`:

1. **Runner target → Signing & Capabilities**: add capabilities
   *Push Notifications*, *Background Modes* (check Voice over IP, Audio,
   Remote notifications), *Siri*, and *App Groups*
   (`group.com.unnanego.freecaller`). Attach the provided
   `Runner/Runner.entitlements`.
2. **Add the Intents extension target**: File → New → Target → *Intents
   Extension*, name `SiriIntents`, bundle id
   `com.unnanego.freecaller.SiriIntents`, no UI extension. Then replace the
   generated sources/plist with the files already in `ios/SiriIntents/`
   (IntentHandler.swift, ContactsStore.swift, Info.plist), and attach
   `SiriIntents.entitlements` (App Groups capability on the extension too).
3. Nothing to do for localization: the app is Russian-only, so the display
   name and permission strings live directly in `ios/Runner/Info.plist` with
   `CFBundleDevelopmentRegion = ru`. (There were `ru.lproj`/`en.lproj`
   `InfoPlist.strings` files here. They were never added to the Runner target,
   so they never reached the bundle and the app shipped as "Freecaller".)
4. Minimum iOS: the calling stack targets iOS 15+; the "default calling
   app" feature needs iOS 18.2+ on her phone.

## 5. Android / Play Console

- When publishing: declare the app as a **calling app** and complete the
  *full-screen intent* + *foreground service (phoneCall, microphone)*
  declarations in Play Console.
- Test on Android 14+ where `USE_FULL_SCREEN_INTENT` needs the runtime
  grant (the app requests it during activation).

## 6. Provision the family

Accounts are never self-registered, so an admin provisions them. PocketBase
listens on loopback, so tunnel to it first:

```bash
ssh -N -L 8090:127.0.0.1:8090 root@<server>          # in another terminal
export PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=…

# One person at a time…
node tools/admin.mjs add-user "Аида" +79150000001 aida@example.com
node tools/admin.mjs link aida@example.com pavel@example.com   # mutual contacts

# …or the whole roster from a file (idempotent — re-run it when someone joins).
cp deploy/pocketbase/roster.example.json deploy/pocketbase/roster.json  # then edit
node tools/admin.mjs apply deploy/pocketbase/roster.json
node tools/admin.mjs list
```

The email address is the credential — it must be a mailbox that person (or
whoever sets up their phone) can actually open. (App Store review accounts are
the exception: their codes are pinned to constants server-side, so nobody has
to open those inboxes — see the runbook.)

On each phone: install the app, type the email, read the 8-digit code out of
that mailbox, done. Sign-in persists for the life of the install (the app
re-issues the token on every launch).

Then make **one supervised test call** in each direction: the OS asks for
microphone + camera permission on the first call — the helper should be
present to approve it (it never asks again).

## 7. On her iPhone specifically

- Language/locale Russian; enable VoiceOver.
- iOS 18.2+: Settings → Apps → Default Apps → Calls → «Звонилка», after
  which plain «Позвони Аиде» works (no app name needed).
- Otherwise: «Привет Siri, позвони Аиде через Звонилку».
