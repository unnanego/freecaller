# Google Play — Data Safety form answers (Freecaller / Звонилка)

Derived from the code (functions/src/contacts.ts, invite.ts, auth.ts; LiveKit media path).
Fill this into Play Console → App content → Data safety.

## Top-level
- **Does your app collect or share any of the required user data types?** → **Yes**
- **Is all of the user data collected by your app encrypted in transit?** → **Yes** (HTTPS/WSS + LiveKit encrypted media)
- **Do you provide a way for users to request that their data be deleted?** → **Yes** (email request; see privacy policy)

## Data types — collected (none "shared" with third parties)
"Shared" = No for everything: Firebase/LiveKit are service providers processing on your behalf, not third-party recipients.

| Data type (Play category) | Collected | Shared | Purpose | Ephemeral? | Optional? |
|---|---|---|---|---|---|
| **Name** (Personal info) | Yes | No | App functionality, Account management | No (stored) | Required |
| **Phone number** (Personal info) | Yes | No | App functionality, Account management | No (stored) | Required |
| **Contacts** (Contacts) | Yes | No | App functionality (find family already on the app) | **Yes — processed ephemerally** (numbers sent to `matchContacts`, matched, not stored) | Optional (permission) |
| **Device or other IDs** (Device ID) | Yes | No | App functionality (call routing, notifications) | No | Required |
| **Diagnostics** (App info and performance) | Yes | No | App functionality (diagnose the audio route on a device we cannot reach) | No (kept 14 days) | Required |

Notes per item:
- **Name / Phone**: stored in the user's profile on our server so family can find/call them.
- **Contacts**: the app uploads address-book phone numbers to match against registered users, then discards them — mark **"processed ephemerally"** (Play shows this instead of a retention claim).
- **Device/IDs**: per-install device id + FCM push token, used to ring the right device.
- **Diagnostics**: **Android only.** During a call the app posts one line describing what happened to the audio route — phone model, API level, the audio mode, which output device the system reported and which one it actually routed to — to our own `diagnostics` collection, purged after 14 days (`pb_hooks/diagnostics.pb.js`). It exists because the phone that gets this wrong belongs to the primary user, in another country and never on a cable, so its Android log is unreachable. No call content, no address-book data, no free text from the user. Delete the collection and the writes become swallowed 404s — see `lib/data/diagnostics_repo.dart`.

## Data types — NOT collected (declare No / don't add)
- **Audio / Voice / Video (call content)**: **Not collected.** Calls are streamed in real time via LiveKit and are **never recorded, stored, or accessed** by you. Real-time comms not retained → not declared.
- **Location, Financial, Health, Messages, Photos, Browsing, Search history**: None.
- **Crash logs / Analytics**: Declare **No** — no Crashlytics, no Analytics. (Diagnostics IS now collected on Android; it moved into the table above.) If you ever enable Firebase Analytics/Crashlytics, add "Crash logs" here too and verify in the Firebase console before submitting.

## Security practices
- Encrypted in transit: **Yes**
- Data deletion request method: **Yes** — users email the address in the privacy policy to delete their account + data.

## Also required nearby (App content section)
- **Privacy policy URL**: host docs/privacy.html → paste the URL
- **App access**: app is invite/login-code gated → provide a working login code + note "private family calling app; sign in with the 6-digit code" so Google can access it if they check
- **Content rating**: questionnaire → all "No" → expect a low rating (everyone/PEGI 3)
- **Target audience**: 18+ (or 13+); it's a family utility, not directed at children
- **Ads**: No ads
