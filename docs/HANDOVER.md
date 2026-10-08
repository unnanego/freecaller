# Handover — 2026-10-08

Where things stand after the MacBook session on 2026-10-08, so work can carry on
from either machine. Newest state first. Update this file (or delete it) when
it stops being true.

## Branch

Everything below is on **`apple-watch-client`**, pushed. **It is not merged into
`main`.** `main` is still at `4585b9b`, and the server and both store builds now
run code that exists only on this branch. Merge it before anything else
branches from `main`.

| Commit | What |
|---|---|
| `0a198de` | Apple Watch peer client: Go `deploy/watch-bridge`, the watch app's Swift, server `watchos` + `answeredOn` |
| `edd052d` (merged in) | Caller no longer stuck on «Соединение…»; draggable self-view |
| `50a602f` | Xcode target `FreecallerWatch` (+ `AudioToolbox` → `CoreAudioTypes` compile fix) |
| `4041c04` | Phones/tablets set `answeredOn` too, so one device answering stops the others ringing |
| `dbe1457`, `dfa0060` | 1.1.6 (21), then the watch app embedded in the iPhone app, 1.1.6 (22) |
| `7c44063` | A finished call's record is final (the other side can no longer rewrite `endedBy`/`endedAt`) |
| `7bf8b57` | `docs/e2ee-plan.md` |
| this commit | Android compile/target SDK 37, 1.1.6 (23), this file |

## What is live

**Server (Moscow box, 176.112.216.205)**: deployed from this branch, and
`verify.sh` passes all 89 checks.
- PocketBase: migration `1791400000_watch_client` (`calls.answeredOn`,
  `devices.platform` += `watchos`), the answered-elsewhere cancel push, and the
  final-call rule.
- `/etc/freecaller/push.json`: `apns.watchBundleId =
  com.unnanego.freecaller.watchkitapp`.
- Caddy: `handle /bridge/*` → `127.0.0.1:8095`, everything else → PocketBase
  as before.
- `watch-bridge.service`: running, about 4 MB. `BRIDGE_ECHO=1` is still on. It
  needs a valid account token, so it isn't open to anyone, but set it to 0 when
  watch testing is over.
- Backup taken before the deploy: `/root/backup-watch-20261008-095248` (DB,
  Caddyfile, push.json, hooks, push.py).

**Stores**
- iOS: **1.1.6 (22)** on TestFlight, watch app included. (21) is the same
  without the watch.
- Android: **1.1.6 (22)** rolled out on the internal track. **1.1.6 (23)**
  targets SDK 37 and is uploaded to internal as a **draft**, not rolled out
  (see below). Production is still 1.1.5 (20).

## Open work, in order

1. **Apple Watch on a real device.** The watch is paired to the son's iPhone, not to pepyachka. Install
   TestFlight (22) on that iPhone, and Звонилка lands on the watch through the
   Watch app. Then follow `docs/watch-plan.md`, "Test plan", from step 1:
   - hand-off;
   - Diagnostics: Opus must read «работает», push «зарегистрирован»;
   - the echo test on Wi-Fi and on LTE;
   - calls in both directions;
   - both devices on one account.

   The watch account for testing is **Apple Review**
   (`applereview@holographica.space`), which has no phone signed in.
2. **Server path without a watch** (`tools/fakewatch.mjs`). Already run once:
   ringing, answering, LiveKit and the bridge all work. Audio stalled only
   because the Mac runs Cloudflare WARP (see gotchas). For a clean echo run, use
   a network without WARP:
   ```
   PB_URL=https://pb.holographica.space node tools/fakewatch.mjs applereview@holographica.space unnanego@gmail.com --seconds=60
   ```
3. **Android SDK 37 build (23).**
   - Make sure the **contacts declaration** now appears in Play Console (Контент
     приложения), and file it. The text, in English and Russian, is below.
   - Before rolling (23) out of draft, test Android 17 behaviour on the Pixel: a
     locked-screen incoming call, the speaker, contacts. The Pixel only accepts
     Play-signed builds, so roll out to internal and update from Play.
4. **E2EE**: `docs/e2ee-plan.md`. Two decisions are open at the end of that
   file; nothing is implemented yet.
5. **Merge `apple-watch-client` → `main`.**

### Contacts declaration text (Play Console)

> Freecaller is a voice and video calling app for families. Its core feature is
> contact discovery: it reads the device address book, sends the phone numbers
> to our server only to find which of the user's contacts are registered
> Freecaller users, and shows those contacts as callable. Matched numbers are
> not stored. The app also displays callers under the name the user saved in
> their own address book. This needs the full contact list, because the user
> can't know in advance which contacts use the app, so the Contact Picker can't
> provide this function. Before any contact data leaves the device, the app
> shows a consent screen explaining the upload. Users can limit which contacts
> appear in the app, and nothing is read or uploaded without that consent. The
> Contact Picker is already used where it fits: choosing a single contact to
> invite.

Russian version: same content. Translate from the above, or see the
2026-10-08 session.

## Gotchas found this session

- **Xcode drops its Apple accounts now and then.** With an account,
  `flutter build ipa --release --export-options-plist=ios/ExportOptions.plist`
  works and includes the watch app. Without one, archive and export with the
  App Store Connect API key:
  ```
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
    -destination generic/platform=iOS -archivePath build/ios/archive/Runner.xcarchive \
    -allowProvisioningUpdates -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_R8JSXTZRG7.p8 \
    -authenticationKeyID R8JSXTZRG7 -authenticationKeyIssuerID 9361f0c2-10ac-409e-bc72-8e29c63607ed archive
  ```
  Then run `-exportArchive` with the same three `-authentication*` flags.
  First run `flutter build ios --release` (or `flutter build ipa`) so
  `Generated.xcconfig` carries the new version.
- **The watch target** was created with the `xcodeproj` Ruby gem, not in the
  Xcode GUI. Things that must stay as they are:
  - `SUPPORTED_PLATFORMS = watchos watchsimulator`. Without it, archiving the
    iOS scheme builds the watch app with the iPhone SDK and fails on its icon.
  - **Embed Watch Content** sits before **Thin Binary**. The other way round is
    a Flutter build cycle.
  - The watch's version comes from `ios/FreecallerWatch/FreecallerWatch.xcconfig`,
    which includes `Generated.xcconfig`.
  - Signing team **R9577QC7DM** (personal), never the Analog teams.
- **Cloudflare WARP on the Mac** inspects TLS and stalls long-lived
  WebSockets: 500 echo frames out, about 65 back, while the same test from the
  server gets 500/500. Node also needs `NODE_USE_SYSTEM_CA=1` there to trust
  WARP's certificate. Neither is a server problem.
- **Android SDK 37**: `compileSdk`/`targetSdk` are now hard-coded to 37 in
  `android/app/build.gradle.kts`, because Flutter 3.44 defaults to 36. Install
  `platforms;android-37.0` and `build-tools;37.0.0` with `sdkmanager` on a new
  machine. On the Mac, `sdkmanager` needs `JAVA_HOME` set to openjdk@17.
- **Play uploads**: `node tools/play.mjs upload [--draft]`, with the key at
  `android/play-service-account.json`. The key is gitignored; copy it from
  Google Drive `My Drive/dev/Freecaller/play-service-account.json`. The Play API
  can't file policy declarations; those are Console only.
- **verify.sh** prompts for the PocketBase superuser password. From the Mac,
  where `tools/pb.mjs` keeps it in the Keychain:
  ```
  security find-generic-password -s freecaller-pb -w | ssh root@176.112.216.205 'cd /var/lib/pocketbase && bash verify.sh'
  ```
  On Windows, type the password when it asks.
- **watch-bridge** needs Go to deploy (`bash deploy/watch-bridge/deploy.sh`).
  It cross-compiles, so it works from Windows too.

## On the Windows machine

- The Swift parts (watch app, `WatchSync.swift`) can be edited but not built.
  iOS builds and uploads happen on the Mac.
- Dart, Android, the server, watch-bridge and the Node tools all work. For
  `tools/*.mjs`, set `PB_SUPERUSER_EMAIL`/`PB_SUPERUSER_PASSWORD` (there is no
  Keychain).
