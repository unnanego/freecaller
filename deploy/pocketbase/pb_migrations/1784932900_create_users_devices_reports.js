/// <reference path="../pb_data/types.d.ts" />

// Auth + roster + push-token collections. Replaces:
//   users/{uid}                    -> `users` (an auth collection: the profile
//                                     and the credential are now one record)
//   users/{uid}/devices/{id}       -> `devices` (PocketBase has no subcollections)
//   users/{uid}/private/creds      -> gone; email OTP replaces the login code
//   activationCodes / loginCodes   -> gone; email OTP replaces both
//   reports/{id}                   -> `reports`
//
// NOTE: PocketBase ships with a default `users` auth collection, so this
// migration *adapts* that one rather than creating it (collection names are
// unique, case-insensitively).
migrate(
  (app) => {
    // ---- users (adapt the built-in auth collection) --------------------------
    const users = app.findCollectionByNameOrId("users")

    // Passwordless by design: email one-time codes only, no passwords anywhere.
    users.passwordAuth.enabled = false

    // 15 minutes rather than the 180s default: the primary user is a blind
    // 73-year-old and setup is admin-assisted, so a code that expires while
    // someone reads it aloud is a real failure mode. The threat model is a
    // private family roster, not a public service.
    users.otp.enabled = true
    users.otp.duration = 900
    users.otp.length = 8

    // ~1 year. A device authenticates once (assisted, for the elderly user) and
    // must never be silently logged out afterwards — failing to receive a call
    // because a token quietly expired is the worst outcome this app has.
    // Caveat: PocketBase can only revoke these wholesale, by rotating the
    // collection's token secret.
    users.authToken.duration = 31536000

    // The roster is readable by the whole signed-in family — that is the point
    // of the app.
    users.listRule = '@request.auth.id != ""'
    users.viewRule = '@request.auth.id != ""'

    // Accounts are provisioned by the family admin (superuser), never
    // self-registered — same as the old `allow create: if false`.
    users.createRule = null

    // Owner-only. *Which fields* an owner may change is enforced in
    // pb_hooks/users.pb.js (displayName only), mirroring the old rule.
    users.updateRule = "id = @request.auth.id"

    // App Store Guideline 5.1.1(v): the user must be able to delete their own
    // account from inside the app. In Firebase this needed a Cloud Function
    // (Admin SDK) because clients were forbidden to delete; here the user
    // deletes their own record directly and the cascade does the rest.
    users.deleteRule = "id = @request.auth.id"

    users.fields.add(
      new TextField({ name: "displayName", required: true, max: 255 }),
    )
    users.fields.add(new TextField({ name: "phone", max: 64 }))
    users.fields.add(
      new RelationField({
        name: "contacts",
        collectionId: users.id,
        // cascadeDelete stays FALSE: deleting a user must not delete the people
        // who had them as a contact. PocketBase instead strips the dangling id
        // out of everyone else's `contacts` automatically — exactly what step 4
        // of the old deleteAccount() function did by hand.
        cascadeDelete: false,
        maxSelect: 50,
        required: false,
      }),
    )

    // Unused PocketBase defaults; `displayName` above is the real one.
    users.fields.removeByName("name")
    users.fields.removeByName("avatar")

    app.save(users)

    // ---- devices ------------------------------------------------------------
    const devices = new Collection({
      type: "base",
      name: "devices",
      fields: [
        {
          type: "relation",
          name: "user",
          required: true,
          collectionId: users.id,
          // Deleting the account wipes its push tokens with it — no orphaned
          // devices that could still be pushed to.
          cascadeDelete: true,
          maxSelect: 1,
        },
        {
          type: "select",
          name: "platform",
          required: true,
          maxSelect: 1,
          values: ["ios", "android"],
        },
        { type: "text", name: "voipToken", max: 255 },
        { type: "text", name: "fcmToken", max: 512 },
        { type: "autodate", name: "created", onCreate: true },
        { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
      ],

      // Push tokens are owner-only, in both directions.
      listRule: "user = @request.auth.id",
      viewRule: "user = @request.auth.id",
      createRule: '@request.auth.id != "" && @request.body.user = @request.auth.id',
      updateRule: "user = @request.auth.id",
      deleteRule: "user = @request.auth.id",

      indexes: ["CREATE INDEX idx_devices_user ON devices (user)"],
    })
    app.save(devices)

    // ---- reports ------------------------------------------------------------
    const reports = new Collection({
      type: "base",
      name: "reports",
      fields: [
        // Deliberately a plain text field, not a relation: a child-safety
        // report must survive the reporter deleting their account, with the
        // reporting uid still attached. A cascading relation would destroy it.
        { type: "text", name: "reporterUid", required: true, max: 255 },
        { type: "text", name: "type", max: 64 },
        { type: "text", name: "message", max: 5000 },
        { type: "autodate", name: "created", onCreate: true },
      ],

      // Anyone signed in may file one; clients can never read them back.
      // Reviewed out-of-band by a superuser.
      createRule:
        '@request.auth.id != "" && @request.body.reporterUid = @request.auth.id',
      listRule: null,
      viewRule: null,
      updateRule: null,
      deleteRule: null,
    })
    app.save(reports)
  },
  (app) => {
    for (const name of ["reports", "devices"]) {
      try {
        app.delete(app.findCollectionByNameOrId(name))
      } catch (err) {
        // already gone
      }
    }

    // `users` is a PocketBase built-in: revert our changes rather than delete it.
    const users = app.findCollectionByNameOrId("users")
    users.passwordAuth.enabled = true
    users.otp.enabled = false
    users.listRule = null
    users.viewRule = null
    users.createRule = null
    users.updateRule = null
    users.deleteRule = null
    users.fields.removeByName("displayName")
    users.fields.removeByName("phone")
    users.fields.removeByName("contacts")
    app.save(users)
  },
)
