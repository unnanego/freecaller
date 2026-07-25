/// <reference path="../pb_data/types.d.ts" />

// Tell someone signing in with an unknown address that it is unknown.
//
// PocketBase answers request-otp with 200 and a fabricated otpId when no
// account matches, so that the endpoint cannot be used to discover who has an
// account. The cost is that the app walks the user to the "enter the code"
// screen and leaves them waiting for mail that was never sent — with no way to
// tell that from a slow inbox. Anyone whose account was deleted, or who typos
// their address, is simply stuck.
//
// That protection is worth very little here and the confusion is expensive.
// The roster is a private family of about ten people, invite-only, and every
// member can already list the whole roster once signed in; an attacker learning
// that some address has an account learns nothing they could act on, since the
// credential is possession of that mailbox. Whereas the failure mode above is
// hit by exactly the people we care about most — an elderly user and whoever is
// helping them set up the phone.
//
// So: fail honestly. The event fires even when nothing matched (e.record is
// null), which is what makes this possible without a second endpoint.
onRecordRequestOTPRequest((e) => {
  if (!e.record) {
    throw new NotFoundError("Нет аккаунта с такой почтой")
  }

  e.next()
}, "users")
