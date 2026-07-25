/// <reference path="../pb_data/types.d.ts" />

// Owner-side restrictions and account-deletion cleanup for the `users` auth
// collection.

// The old Firestore rule let the owner edit exactly one field:
//   allow update: if request.auth.uid == uid
//     && ...affectedKeys().hasOnly(['displayName'])
// Everything else (phone, contacts, email, verified) is provisioned by the
// admin. Reproduce that here, because the API rule can only express "is the
// owner", not "may only touch this field".
//
// The check is scoped to the record's owner on purpose: a superuser editing the
// roster from the dashboard is not the owner, so it passes straight through.
onRecordUpdateRequest((e) => {
  const auth = e.auth
  const isOwner = auth && auth.id === e.record.id

  if (isOwner) {
    const previous = e.record.original()
    const locked = ["email", "verified", "phone", "contacts"]

    for (let i = 0; i < locked.length; i++) {
      const field = locked[i]
      if (String(e.record.get(field)) !== String(previous.get(field))) {
        throw new ForbiddenError(
          "only displayName is user-editable (" + field + " is admin-managed)",
        )
      }
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
