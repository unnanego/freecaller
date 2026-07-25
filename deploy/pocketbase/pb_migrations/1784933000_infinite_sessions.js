/// <reference path="../pb_data/types.d.ts" />

// Auth sessions at the longest duration PocketBase permits.
//
// There is no "never expires": auth tokens are stateless JWTs with a mandatory
// `exp`, and PocketBase validates `authToken.duration` against a hard maximum of
// 94670856 seconds (3 years). Anything larger is rejected outright:
//   authToken: (duration: must be no greater than 94670856.)
//
// So "infinite" is achieved in two halves:
//   1. this migration — the 3-year ceiling, and
//   2. the client calling authRefresh() on launch/resume, which re-issues the
//      token and pushes `exp` out again. A device used even once every 3 years
//      therefore never gets logged out. WITHOUT the client half, sessions do
//      eventually die — the ceiling alone is not enough.
//
// Why it matters: a device authenticates once (admin-assisted, for the blind
// primary user) and must never be silently logged out. Failing to receive a call
// because a token quietly expired is the worst failure this app has, and
// recovering needs someone to read an emailed code aloud.
//
// Revocation still works despite the duration: changing a user record's system
// `tokenKey` invalidates every token previously issued to THAT user (per-user
// logout); rotating the collection's token secret invalidates everyone's. A lost
// phone does not mean a permanently valid credential.
migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users")
    users.authToken.duration = 94670856 // 3 years — PocketBase's maximum
    app.save(users)
  },
  (app) => {
    const users = app.findCollectionByNameOrId("users")
    users.authToken.duration = 31536000 // back to 1 year
    app.save(users)
  },
)
