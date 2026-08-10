# App Store review notes — 1.1.0 (12)

Copy-paste text for **App Store Connect → App Review Information → Notes**, plus
the things that must be true on the server *before* submitting.

Supersedes `appstore-resubmission.md`, which describes build 8's reusable login
codes. Those no longer exist: sign-in is a one-time code emailed to the account,
which a reviewer cannot receive. Everything below depends on that being solved.

---

## Before you submit — three things outside the binary

### 1. Pin sign-in codes for the demo accounts (REQUIRED)

Without this a reviewer literally cannot sign in, which is an automatic
rejection. `pb_hooks/review_otp.pb.js` pins a fixed code for listed accounts;
the mechanism is **off** whenever the config file is absent, which is its normal
state.

On the PocketBase host:

```bash
cat > /etc/freecaller/review-otp.json <<'JSON'
{
  "applereview@holographica.space": "REVIEW_CODE_1",
  "applereview2@holographica.space": "REVIEW_CODE_2",
  "deleteme@holographica.space": "DELETEME_CODE_1",
  "deleteme2@holographica.space": "DELETEME_CODE_2"
}
JSON
chown root:pocketbase /etc/freecaller/review-otp.json
chmod 640 /etc/freecaller/review-otp.json
```

No redeploy needed — the hook reads the file per request.

**The confusing part, worth remembering:** for a pinned account the *emailed*
code stops working and only the fixed one does. Do not debug a review account by
reading its inbox.

**Delete the file when review is over.** That disables the whole mechanism and
returns those accounts to single-use random codes.

### 2. Give `applereview@` a valid phone number (REQUIRED)

**How someone appears in Contacts — the thing that trips everyone up.** The
`contacts` field on the user record does NOT put anybody on the Contacts tab.
Nothing reads it: `contactUids` is parsed into `UserProfile` and never used by a
widget, and `/api/freecaller/match-contacts` scans `"id != {:me}"` — every user
except you, with no roster filter. Linking two accounts to each other in
PocketBase achieves nothing here.

The only gate is **discovery**: a person shows up if their number is in the
DEVICE's address book and normalises to the same E.164 the server stores. So the
reviewer has to add a contact on the phone, and the account's number has to be a
number that parses.

| Email | uid | Phone | Parses? |
|---|---|---|---|
| `applereview@holographica.space` | `08mgln469wbh647` | `+11111111111` | **NO** |
| `applereview2@holographica.space` | `kofm8p9fnc6sdlx` | `+79161231010` | yes |
| `deleteme@holographica.space` | `3o0rh9j2s18j75o` | `+79161231111` | yes |
| `deleteme2@holographica.space` | `i2pc015h0ezmed6` | `+79161231112` | yes |

`+11111111111` is not valid in any numbering plan. The client validates before
uploading and drops it, so that account can never be matched by anyone. Change it
in the dashboard (`users` → record → `phone`) to something that parses —
`+79161231011` is verified good and keeps the block together.

Also worth tidying, neither blocking: `deleteme@` and `deleteme2@` are both
named "deleteme2", and both sit in a real family member's roster — unlink them
once review is over.

### 3. Record the demo video (REQUIRED — this is what 2.1 asked for)

Apple rejected build 4 under **Guideline 2.1** asking for a video on a *physical*
device showing the CallKit services in use. That requirement has not gone away.
Capture the iPhone screen **from a Mac via QuickTime** (File → New Movie
Recording → camera = the iPhone): iOS Screen Recording is torn down the moment a
call takes the audio session, so it cannot record the very thing being asked for.

Show, in one take: incoming call ringing on the lock screen (CallKit) → answer →
two-way audio → switch to video → hang up. Then «Позвони …» via Siri.

Host it somewhere with no login (unlisted YouTube/Vimeo is fine) and put the URL
in the Notes below.

---

## Paste into App Review Information → Notes

> Freecaller («Звонилка») is a private, invite-only calling app for one family.
> It has no public sign-up by design: accounts are created only by invitation
> from an existing member, so there is no registration screen to test.
>
> The interface is in Russian only. Its primary user is a blind, Russian-speaking
> woman in her seventies; the app exists so she can answer calls and place them
> by voice with Siri. Everything else is operated by her family.
>
> DEMO ACCOUNTS — two are provided so you can call between two devices:
>   Account 1: applereview@holographica.space    code: REVIEW_CODE_1
>   Account 2: applereview2@holographica.space   code: REVIEW_CODE_2
>
> HOW TO SIGN IN: launch the app, type the email address, tap «Прислать код»
> (Send code), then type the 8-digit code above and tap «Активировать»
> (Activate). The code above is fixed for these review accounts and can be
> reused as often as you need — you do not need access to the mailbox.
>
> DEMO VIDEO (Guideline 2.1): DEMO_VIDEO_URL
> Recorded on a physical iPhone, showing an incoming CallKit call on the lock
> screen, answering it, two-way audio, switching to video, ending the call, and
> placing a call with Siri.
>
> IF YOU HAVE TWO DEVICES — sign in as Account 1 on one and Account 2 on the
> other, then on each device:
>   1. Open Apple's Contacts app and add a contact with the OTHER account's
>      phone number, exactly as written including the "+":
>        Account 1 → +79161231011
>        Account 2 → +79161231010
>   2. In Freecaller, open the «Контакты» tab, tap «Продолжить» (Continue), then
>      allow the system Contacts prompt.
>   3. The other account now appears in the list. Tap the phone icon for a voice
>      call or the camera icon for video.
> This step is needed because the app deliberately has no directory of users: it
> only ever shows people who are already in your own address book, matched by
> phone number. It never displays anyone you have not saved yourself.
>
> IF YOU HAVE ONE DEVICE: the video above shows the full flow. We can also place
> a live call to your device at a time you specify — tell us in the Resolution
> Center and we will ring the account you are signed into. An incoming call needs
> no address-book setup, and once it has arrived you can call back from the
> «Недавние» (Recents) tab, which works without adding a contact.
>
> SIRI: on first launch the app asks for Siri permission. Once the other account
> is in your address book (step 1 above), granting Siri lets you say
> «Позвони Apple review2» to place the call by voice. This is one of only two
> things the primary user can do unaided, which is why the app asks up front.
>
> CONTACTS (Guideline 5.1.2): the app reads and uploads nothing from the address
> book until you tap «Продолжить» (Continue) on the Contacts tab. That screen
> explains that phone numbers are sent to our server only to find which of your
> contacts already use the app, and that they are matched rather than stored. The
> system Contacts prompt appears only after that. Privacy policy:
> https://holographica.space/freecaller/privacy
>
> CONTACTS PERMISSION (Guideline 5.1.1 — addressed in this build): declining the
> system prompt is now final. The app no longer opens Settings after «Don't
> Allow»; it shows a plain explanation that the Contacts list will be empty
> without access, alongside an «Открыть настройки» (Open Settings) link the user
> may use or ignore, and it does not ask a second time. The button on the screen
> preceding the prompt is labelled «Продолжить» (Continue). Contacts are a
> convenience for matching, never a requirement: incoming calls and the
> «Недавние» (Recents) tab work with contacts access denied.
>
> ACCOUNT DELETION (Guideline 5.1.1(v)): Settings → «Удалить аккаунт» → confirm.
> This permanently deletes the profile, contacts and call history in the app,
> with no email or support step.
>
> BACKGROUND MODES: the app uses VoIP (PushKit) to receive incoming calls and
> reports every one to CallKit, which is what allows it to ring while the app is
> closed or the phone is locked.
>
> Thank you.

---

## Fill these in

| Placeholder | What it is |
|---|---|
| `REVIEW_CODE_1` / `REVIEW_CODE_2` | 8 digits each — the app's code field accepts exactly 8 |
| `DEMO_VIDEO_URL` | Publicly reachable, no login |

## Known-harmless warning

Uploading produces an **ITMS-90626** email about the Siri intents extension. It
is expected and has been present on every accepted build — do not "fix" it; past
attempts to silence it caused hard rejections.
