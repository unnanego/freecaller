# Freecaller («Звонилка») — Setup

One-time infrastructure setup. Code assumes bundle/application id
`com.unnanego.freecaller` and App Group `group.com.unnanego.freecaller` —
change consistently in `ios/Runner/AppDelegate.swift`,
`ios/SiriIntents/ContactsStore.swift`, entitlements files,
`android/app/build.gradle.kts`, and `res/xml/shortcuts.xml` if needed.

## 1. Firebase

1. Create a Firebase project, upgrade to the **Blaze** plan (required for
   Cloud Functions; actual usage at family scale rounds to $0).
2. Enable **Firestore** and **Authentication** (no providers needed — we
   sign in with custom tokens only).
3. `npm i -g firebase-tools && firebase login && firebase use --add`
   (writes `.firebaserc`).
4. `dart pub global activate flutterfire_cli && flutterfire configure` —
   registers the iOS + Android apps and overwrites the placeholder
   `lib/firebase_options.dart`. This also downloads
   `android/app/google-services.json` and
   `ios/Runner/GoogleService-Info.plist`.
5. Deploy rules + functions:
   `firebase deploy --only firestore:rules,functions`.

## 2. LiveKit (self-hosted media server)

The media/SFU + TURN server runs on your own VPS. Full recipe (Docker
Compose, domain, firewall) in [`deploy/livekit/README.md`](../deploy/livekit/README.md).
In short: stand up the server, generate an API key/secret, then:

```bash
firebase functions:secrets:set LIVEKIT_API_KEY
firebase functions:secrets:set LIVEKIT_API_SECRET
echo 'LIVEKIT_URL=wss://livekit.YOURDOMAIN.com' >> functions/.env
```

No app code changes — `livekit_client` and `mintLiveKitToken` talk to any
LiveKit server. (LiveKit Cloud's managed free tier is a drop-in alternative
if you ever want it: same three values, `wss://<project>.livekit.cloud`.)

## 3. APNs VoIP push (iOS incoming calls)

1. Apple Developer portal → Keys → new key with **Apple Push Notifications
   service** enabled → download the `.p8`.
2. Function config:
   - secret: `firebase functions:secrets:set APNS_AUTH_KEY` (paste the .p8
     PEM contents)
   - params in `functions/.env`: `APNS_KEY_ID`, `APNS_TEAM_ID`,
     `APNS_BUNDLE_ID=com.unnanego.freecaller`, `APNS_ENV=sandbox`
     (**switch to `production` for TestFlight/App Store builds** — sandbox
     vs production mismatch silently drops pushes).

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
3. Make sure `ru.lproj/` and `en.lproj/` `InfoPlist.strings` are added to
   the Runner target (Localizations: add Russian in project settings).
4. Minimum iOS: the calling stack targets iOS 15+; the "default calling
   app" feature needs iOS 18.2+ on her phone.

## 5. Android / Play Console

- When publishing: declare the app as a **calling app** and complete the
  *full-screen intent* + *foreground service (phoneCall, microphone)*
  declarations in Play Console.
- Test on Android 14+ where `USE_FULL_SCREEN_INTENT` needs the runtime
  grant (the app requests it during activation).

## 6. Provision the family

```bash
cd tools && npm install
export GOOGLE_APPLICATION_CREDENTIALS=~/keys/freecaller-admin.json  # service account
npx tsx admin.ts add-user "Аида" +79150000001      # prints uid + activation code
npx tsx admin.ts add-user "Павел" +79150000002
npx tsx admin.ts link <uidAida> <uidPavel>          # mutual contacts
npx tsx admin.ts code <uid>                         # fresh code if one expired
```

On each phone: install the app, type the 6-digit code, done. Sign-in
persists for the life of the install.

Then make **one supervised test call** in each direction: the OS asks for
microphone + camera permission on the first call — the helper should be
present to approve it (it never asks again).

## 7. On her iPhone specifically

- Language/locale Russian; enable VoiceOver.
- iOS 18.2+: Settings → Apps → Default Apps → Calls → «Звонилка», after
  which plain «Позвони Аиде» works (no app name needed).
- Otherwise: «Привет Siri, позвони Аиде через Звонилку».
