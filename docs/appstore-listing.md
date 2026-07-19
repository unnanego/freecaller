# App Store listing — Freecaller / «Звонилка»

Draft copy to paste into App Store Connect. Russian is the primary language
(your audience); English provided for the secondary locale / reviewer.

---

## Name (30 char max)
- RU: `Звонилка`
- EN: `Freecaller`

## Subtitle (30 char max)
- RU: `Звонки для своих`
- EN: `Calls for your family`

## Promotional text (170 char max, editable anytime)
- RU: `Простые голосовые и видеозвонки для семьи. Только по приглашению — никакой рекламы и лишних контактов.`
- EN: `Simple voice and video calls for family. Invite-only — no ads, no strangers.`

## Keywords (100 char max, comma-separated, no spaces)
- RU: `звонок,видеозвонок,семья,близкие,связь,общение,бесплатно,голос,видео`
- EN: `call,video call,family,relatives,voip,calling,free,voice,video,contacts`

## Description
### RU
Звонилка — это простое приложение для голосовых и видеозвонков между близкими.

Оно создано для семьи: только те, кого вы пригласили, могут вам звонить. Никакой
рекламы, никаких чужих людей и лишних настроек.

• Голосовые и видеозвонки в хорошем качестве
• Регистрация по приглашению — просто введите код от близкого человека
• Вход по коду, без паролей — удобно для любого возраста
• Ваши контакты подсказывают, кто из близких уже в приложении
• Звонки не записываются и не хранятся

Звонилка идеально подходит, чтобы оставаться на связи с родителями, бабушками и
дедушками и всей семьёй.

### EN
Freecaller is a simple app for voice and video calls between close family.

It's built for families: only people you invite can call you. No ads, no
strangers, no complicated settings.

• High-quality voice and video calls
• Invite-based sign-up — just enter a code from a family member
• Sign in with a code, no passwords — easy at any age
• Your contacts show which relatives already use the app
• Calls are never recorded or stored

Freecaller is perfect for staying in touch with parents, grandparents, and your
whole family.

## URLs
- Support URL (required): `https://holographica.space/freecaller` (create a simple page)
- Marketing URL (optional): same or blank
- Privacy Policy URL (required): host `docs/privacy.html` → `https://holographica.space/freecaller/privacy`

## Category
- Primary: **Social Networking**  (alt: Utilities)
- Secondary: optional

## Age rating
Answer the questionnaire; for this app all content answers are "None" →
expected rating **4+**. (No mature content, no user-generated public content —
calls are private between invited contacts.)

## Price
Free (no in-app purchases).

---

## App Privacy questionnaire (Data collection)
Based on the current code. VERIFY the contacts item against your backend before submitting.

| Data type | Collected? | Linked to user? | Used for | Notes |
|---|---|---|---|---|
| Name (display name) | Yes | Yes | App Functionality | You choose a display name |
| Phone number | Yes | Yes | App Functionality | Used to link invited contacts |
| Contacts | Yes | Yes | App Functionality | Address-book phone numbers ARE sent to the server (plaintext E.164, up to 2000) to find which family already use the app. Per `functions/src/contacts.ts` they are matched and returned, NOT stored server-side. Nothing is uploaded until the user accepts an explicit in-app consent screen (Guideline 5.1.2 fix); `NSContactsUsageDescription` also states the upload. Declare "Contacts" collected for App Functionality; not used for tracking. |
| Device ID | Yes | Yes | App Functionality | Per-install device id for push/call routing |
| Push token | Yes | Yes | App Functionality | Firebase Cloud Messaging for incoming calls |
| Audio/Video (call content) | **No** | — | — | Streamed live via LiveKit, not recorded or stored |
| Usage data / Analytics | Confirm | — | — | Only if Firebase Analytics is enabled |

- Used for tracking: **No**
- Data used to track you across apps/websites: **No**

---

## App Review notes (paste into App Review Information → Notes)

Give the reviewer a working login code (the app is invite/login-code gated) plus the two flows Apple asked about. Suggested text:

```
Sign-in: this is a private, invite-only family calling app. Use login code
<REVIEW_CODE> on the sign-in screen (reusable, works on any device). A VPN can
briefly slow the database on first launch — if you see a spinner, tap Retry.

Contacts (Guideline 5.1.2): the app never uploads anything from the address
book until you tap "Allow and find" on the Contacts tab. That consent screen
explains that phone numbers are sent to our server only to find which of your
contacts already use the app; numbers are matched and not stored. See our
Privacy Policy → "Contacts".

Account deletion (Guideline 5.1.1(v)): Settings → "Delete account" → confirm.
This permanently deletes the profile, contacts, login code, and call history
and removes the account entirely (no email or support step required). A screen
recording of this flow is attached.
```

Checklist before resubmitting:
- Deploy the delete function: `firebase deploy --only functions:deleteAccount`.
- Re-host `docs/privacy.html` (updated 19 Jul 2026: contacts-upload wording + in-app deletion) at the Privacy Policy URL.
- Record the account-deletion flow on a physical device and attach it in App Review notes.
- If the reviewer deletes the demo account, it's gone — hand them a dedicated code and be ready to re-mint via `functions/scripts/createReviewAccount.js`.
