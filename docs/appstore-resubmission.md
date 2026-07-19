# App Store resubmission — build 1.0 (8)

Copy-paste text for the resubmission that answers the 2026-07-17 rejection
(Submission 19d92724…): **5.1.2** (Contacts uploaded without consent) and
**5.1.1(v)** (no in-app account deletion). Build `0.1.0+8`.

Before submitting, do these three (outside the app binary):
1. **Re-host** the updated `docs/privacy.html` at the Privacy Policy URL
   (`https://holographica.space/freecaller/privacy`) — the policy now discloses
   the contacts upload and in-app deletion, and both guidelines cross-check it.
2. **App Privacy questionnaire** (App Store Connect → App Privacy): make sure
   **Contacts** is declared **Collected → App Functionality**, *not* used for
   tracking, *not* linked for ads. (Numbers are matched server-side and not
   stored — see the privacy policy.)
3. **Record a screen video** of the account-deletion flow on a physical device
   and attach it in App Review Information → Notes.

---

## 1) Resolution Center reply

> Hello, and thank you for the detailed feedback. Both issues are addressed in
> build 1.0 (8):
>
> **Guideline 5.1.2 — Contacts consent.** The app no longer reads or uploads any
> address-book data until the user gives explicit in-app consent. On the
> Contacts tab (and in Settings → Contact access) the user first sees a screen
> explaining that phone numbers from their address book will be sent to our
> server *only* to find which of their contacts already use the app, and that the
> numbers are matched and not stored. Nothing is transmitted until they tap
> "Allow and find," which appears before the system Contacts permission prompt.
> The `NSContactsUsageDescription` string and our privacy policy also state that
> the numbers are uploaded for matching. Our privacy policy:
> https://holographica.space/freecaller/privacy
>
> **Guideline 5.1.1(v) — Account deletion.** Settings now has a "Delete account"
> option that permanently deletes the account and all associated data (profile,
> contacts, sign-in code, and call history) directly in the app, with a single
> confirmation and no email or customer-service step. A screen recording of the
> full flow is attached in the App Review notes.
>
> Reviewer sign-in code and steps are in the App Review notes. Thank you.

---

## 2) App Review Information → Notes

> This is a private, invite-only family calling app. Sign in on the first screen
> with login code: 047597  (reusable, works on any device).
> A VPN can briefly slow the database on first launch — if you see a spinner,
> tap Retry.
>
> CONTACTS (Guideline 5.1.2): the app uploads nothing from the address book
> until you tap "Allow and find" on the Contacts tab. That consent screen
> explains phone numbers are sent to our server only to find which of your
> contacts already use the app; numbers are matched and not stored. See our
> Privacy Policy → "Contacts."
>
> ACCOUNT DELETION (Guideline 5.1.1(v)): Settings → "Delete account" → confirm.
> This permanently deletes the profile, contacts, sign-in code, and call history
> and removes the account entirely — no email or support step. A screen
> recording of this flow is attached below.
>
> [Attach: account-deletion screen recording]

> ⚠️ Before submitting: confirm code **047597** still signs in (it's a reusable
> review account). Because account deletion now exists, if a reviewer deletes
> that account it's gone — consider minting a second, throwaway code for the
> deletion demo with `functions/scripts/createReviewAccount.js` and listing both.

---

## 3) "What's New in This Version" (release notes)

RU:
> • Теперь можно удалить аккаунт прямо в приложении: Настройки → «Удалить аккаунт».
> • Поиск контактов в приложении теперь только с вашего явного согласия.
> • Улучшена стабильность звонков на медленных сетях.

EN:
> • You can now delete your account right in the app: Settings → Delete account.
> • Finding contacts who use the app now happens only with your explicit consent.
> • Improved call reliability on slow networks.

---

## 4) Unchanged

Name, subtitle, keywords, description, category, age rating, price — all as in
`appstore-listing.md`. No screenshot changes required for these fixes.
