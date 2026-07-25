# New machine setup — Freecaller / «Звонилка»

How to get a fresh Mac ready to build, run, release, and deploy this project.
Nothing secret lives in git — the pieces you must restore from Google Drive
are listed at the bottom.

---

## 1. Install the toolchain (Homebrew)
```bash
brew install --cask flutter          # or manage the SDK yourself
brew install --cask android-commandlinetools
brew install openjdk@17 cocoapods node libimobiledevice
```
- Install **Xcode** from the App Store, then: `sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch`.
- Env (add to `~/.zshrc`):
  ```bash
  export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
  export PATH="$ANDROID_HOME/platform-tools:$PATH"          # adb
  export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
  ```
- Accept Android licenses: `flutter doctor --android-licenses`.

## 2. Clone
```bash
git clone git@github.com:unnanego/freecaller.git
cd freecaller
flutter pub get
(cd ios && pod install)          # after the first iOS build fetches plugins
```

## 3. Restore signing secrets from Drive (gitignored — not in the clone)
From `My Drive/dev/Freecaller/android-signing/`:
```bash
cp "<Drive>/android-signing/key.properties"          android/key.properties
cp "<Drive>/android-signing/freecaller-release.jks"  android/app/freecaller-release.jks
```
Without these, Android release builds fall back to debug signing (Play rejects them).

## 4. Sign in
- **Xcode signing:** Xcode → Settings → Accounts → add the Apple ID for team `R9577QC7DM`. Automatic signing then re-provisions on first device build.

## 5. Verify
```bash
flutter doctor -v        # all green except optional bits
```

## 6. Build / run / release
Device IDs: iPhone (Паша) `00008140-00097811012A801C` · Pixel 7 Pro (Оля) `2A081FDH300GUK`.

```bash
# Run on device (iOS MUST be --release untethered; debug crashes on ProMotion iOS26)
flutter run --release -d <iphone-id>
flutter install --release -d <pixel-id>   # Android: install without launch, survives session end

# App Store / TestFlight
flutter build ipa --release
API_PRIVATE_KEYS_DIR="<Drive>/dev/Freecaller" \
  xcrun altool --upload-app --type ios -f build/ios/ipa/*.ipa \
  --apiKey R8JSXTZRG7 --apiIssuer <ISSUER_ID>     # issuer from ASC → Users & Access → Integrations

# Google Play (Internal testing) — upload this AAB in the Play Console
flutter build appbundle --release
# -> build/app/outputs/bundle/release/app-release.aab
```
Bump `version:` in `pubspec.yaml` before each store upload (duplicate build numbers are rejected).

## 7. Backend (PocketBase)
The backend is not deployed from here — it runs on the server, and updates
are files copied into place (see `deploy/pocketbase/`):
```bash
scp deploy/pocketbase/pb_hooks/*.pb.js  root@<server>:/var/lib/pocketbase/pb_hooks/
scp deploy/pocketbase/pb_migrations/*   root@<server>:/var/lib/pocketbase/pb_migrations/
ssh root@<server> systemctl restart pocketbase     # hooks + migrations load at start
ssh root@<server> 'cd /var/lib/pocketbase && bash verify.sh'
```
Roster admin runs locally against a tunnel (PocketBase is loopback-only):
```bash
ssh -N -L 8090:127.0.0.1:8090 root@<server>
PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=… node tools/admin.mjs list
```
The app must be built with the public URL:
`flutter build ipa --release --dart-define=PB_URL=https://pb.YOURDOMAIN`.

---

## Secret inventory (locations only — never in git)
| Secret | Restore to / used by | Drive location |
|---|---|---|
| Android keystore `freecaller-release.jks` | `android/app/` | `My Drive/dev/Freecaller/android-signing/` |
| `key.properties` (keystore passwords) | `android/` | `My Drive/dev/Freecaller/android-signing/` |
| App Store Connect API key `AuthKey_R8JSXTZRG7.p8` | `altool` uploads (`API_PRIVATE_KEYS_DIR`) | `My Drive/dev/Freecaller/` |
| Firebase service-account `.json` | FCM v1 sending from `push.py` | `My Drive/work/Holographica/Freecaller/` → server `/etc/freecaller/` |
| APNs auth key (VoIP push) | `push.py` on the PocketBase host | server `/etc/freecaller/` (re-upload from Apple if ever rotated) |
| PocketBase superuser password | `tools/admin.mjs`, the PB dashboard | password manager |

`GoogleService-Info.plist` / `google-services.json` are committed (client config, not sensitive).
Keep the Drive account on 2FA — it now holds full app-signing ability.
