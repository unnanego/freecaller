/// <reference path="../pb_data/types.d.ts" />

// Owner-side restrictions and account-deletion cleanup for the `users` auth
// collection.

// The old Firestore rule let the owner edit exactly one field:
//   allow update: if request.auth.uid == uid
//     && ...affectedKeys().hasOnly(['displayName'])
// Everything else was provisioned by the admin. That is still the shape, but
// the owner now also keeps their own displayName, phone and avatar up to date —
// a family moves house and changes numbers without the admin being awake.
//
// Still admin-only, and for different reasons each:
//   contacts  — who you may call is the roster, not a self-service list
//   verified  — it is a claim ABOUT the account, not a property of it
//   email     — the credential. It changes only through
//               pb_hooks/email_change.pb.js, which proves the new mailbox is
//               reachable first; a straight write here would let a typo lock
//               someone out of an account that has no password to fall back on.
//
// The check is scoped to the record's owner on purpose: a superuser editing the
// roster from the dashboard is not the owner, so it passes straight through.
// The email-change hook writes through $app, which skips request hooks entirely.
onRecordUpdateRequest((e) => {
  // Best-effort E.164, same rules as the invite/match handlers — hook callbacks
  // run in separate goja runtimes, so this cannot be shared with them.
  const toE164 = (raw) => {
    const trimmed = String(raw || "").trim()
    if (!trimmed) return ""
    const plus = trimmed.charAt(0) === "+"
    let digits = trimmed.replace(/\D/g, "")
    if (!plus && digits.length === 11 && digits.charAt(0) === "8") {
      digits = "7" + digits.slice(1)
    }
    if (digits.length < 8 || digits.length > 15) return ""
    return "+" + digits
  }

  const auth = e.auth
  const isOwner = auth && auth.id === e.record.id

  if (isOwner) {
    const previous = e.record.original()
    const locked = ["email", "verified", "contacts"]

    for (let i = 0; i < locked.length; i++) {
      const field = locked[i]
      if (String(e.record.get(field)) !== String(previous.get(field))) {
        throw new ForbiddenError(
          field + " is admin-managed and cannot be changed here",
        )
      }
    }

    const phone = String(e.record.get("phone") || "")
    if (phone !== String(previous.get("phone") || "")) {
      const e164 = toE164(phone)
      if (!e164) {
        throw new BadRequestError("Неверный номер телефона")
      }

      // The number is how the app finds you in someone's address book, so two
      // accounts holding one number would make discovery ambiguous — and the
      // invite route already refuses to create that state. Enforce the same
      // thing here, by scanning the roster and normalizing both sides: the
      // stored format is whatever an admin once typed.
      const roster = $app.findRecordsByFilter("users", "id != {:me}", "", 500, 0, {
        me: e.record.id,
      })
      for (let i = 0; i < roster.length; i++) {
        if (toE164(roster[i].get("phone")) === e164) {
          // Names nobody: which account holds the number stays on the server,
          // for the same reason the invite route refuses to say.
          throw new ApiError(409, "Этот номер уже занят", null)
        }
      }

      // Store what discovery will look for, not what was typed.
      e.record.set("phone", e164)
    }
  }

  e.next()
}, "users")

// Account deletion — App Store Guideline 5.1.1(v).
//
// The user deletes their own record (deleteRule: id = @request.auth.id) and
// everything tied to them must go with it. Coverage compared to the old
// deleteAccount() Cloud Function:
//
//   devices              -> automatic (devices.user relation, cascadeDelete)
//   others' contacts     -> automatic (PocketBase strips the dangling id)
//   auth record          -> automatic (the record *is* the credential here)
//   loginCodes           -> n/a, email OTP has no stored codes
//   activationCodes      -> n/a, same
//   call history         -> THIS HOOK (callerId/calleeId are plain text, so
//                          there is no relation to cascade from)
//   reports              -> deliberately NOT deleted: a child-safety report
//                          must outlive the reporter's account
//
// Runs before the delete inside the same transaction, so if the account delete
// fails the call history is not lost.
onRecordDelete((e) => {
  const uid = e.record.id

  const calls = $app.findRecordsByFilter(
    "calls",
    "callerId = {:uid} || calleeId = {:uid}",
    "",
    1000,
    0,
    { uid: uid },
  )

  for (let i = 0; i < calls.length; i++) {
    $app.delete(calls[i])
  }

  console.log(
    "account deleted: " + uid + " (purged " + calls.length + " call record(s))",
  )

  e.next()
}, "users")
