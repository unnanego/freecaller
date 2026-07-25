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

Notes per item:
- **Name / Phone**: stored in the user's profile on our server so family can find/call them.
- **Contacts**: the app uploads address-book phone numbers to match against registered users, then discards them — mark **"processed ephemerally"** (Play shows this instead of a retention claim).
- **Device/IDs**: per-install device id + FCM push token, used to ring the right device.

## Data types — NOT collected (declare No / don't add)
- **Audio / Voice / Video (call content)**: **Not collected.** Calls are streamed in real time via LiveKit and are **never recorded, stored, or accessed** by you. Real-time comms not retained → not declared.
- **Location, Financial, Health, Messages, Photos, Browsing, Search history**: None.
- **Crash logs / Diagnostics / Analytics**: Declare **No** — *unless* you have Firebase Analytics/Crashlytics enabled. If you do, add "Crash logs" + "Diagnostics" under App info and performance (collected, not shared, Analytics/App functionality). Verify in your Firebase console before submitting.

## Security practices
- Encrypted in transit: **Yes**
- Data deletion request method: **Yes** — users email the address in the privacy policy to delete their account + data.

## Also required nearby (App content section)
- **Privacy policy URL**: host docs/privacy.html → paste the URL
- **App access**: app is invite/login-code gated → provide a working login code + note "private family calling app; sign in with the 6-digit code" so Google can access it if they check
- **Content rating**: questionnaire → all "No" → expect a low rating (everyone/PEGI 3)
- **Target audience**: 18+ (or 13+); it's a family utility, not directed at children
- **Ads**: No ads
