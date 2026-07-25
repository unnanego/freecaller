/// <reference path="../pb_data/types.d.ts" />

// Fixed sign-in codes for App Store review accounts.
//
// Sign-in is a code emailed to the account, which an App Store reviewer cannot
// receive without also being handed a mailbox — a second site to log into,
// under a 15-minute expiry, on an app that has already been rejected once for a
// sign-in that stalled. So for a small, explicitly listed set of accounts the
// code is pinned to a constant instead: the reviewer types the email, then the
// code from the review notes, through the ordinary activation screen. Nothing
// in the app knows this exists.
//
// HOW: PocketBase creates an `_otps` record (holding a HASH of the generated
// code) and then emails the plaintext. This hook runs before that record is
// stored and overwrites the password with the fixed code, so the fixed code is
// what validates.
//
// CONSEQUENCE, and the one confusing part: for a listed account the emailed
// code does NOT work — only the fixed one does. That is deliberate (the point
// is to not need the mailbox at all), but do not debug a review account by
// reading its inbox.
//
// CONFIG: /etc/freecaller/review-otp.json, a flat {email: code} map, e.g.
//
//     { "review1@holographica.space": "24681357" }
//
// Install root:pocketbase, chmod 640, like push.json. **Delete the file when
// review is over** — that disables the whole mechanism, no redeploy needed.
// Accounts not in the file are untouched, so the family's codes stay
// single-use and random.
//
// Everything the handler needs is declared inside it: hook callbacks run in
// separate goja runtimes and cannot see file-level variables.
onRecordCreate((e) => {
  try {
    const users = $app.findCollectionByNameOrId("users")

    // _otps is shared by every auth collection; only ours is interesting.
    if (e.record.get("collectionRef") === users.id) {
      let codes = null
      try {
        codes = JSON.parse(toString($os.readFile("/etc/freecaller/review-otp.json")))
      } catch (err) {
        // No file (the normal state outside a review) — nothing to pin.
        codes = null
      }

      if (codes) {
        const user = $app.findRecordById("users", e.record.get("recordRef"))
        const email = String(user.get("email") || "").toLowerCase()
        const fixed = String(codes[email] || "").trim()

        if (fixed) {
          e.record.setPassword(fixed)
          console.log("review otp: pinned fixed code for " + email)
        }
      }
    }
  } catch (err) {
    // Never block a sign-in over this: a broken config file must cost a
    // reviewer their fixed code, not lock the whole family out.
    console.log("review otp hook failed (ignored): " + err)
  }

  e.next()
}, "_otps")
