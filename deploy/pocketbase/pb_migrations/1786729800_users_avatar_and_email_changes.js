/// <reference path="../pb_data/types.d.ts" />

// Makes a profile editable by the person it belongs to: a picture, and a way to
// move the account to a different mailbox.
//
// Two things happen here:
//
//   1. `avatar` comes back to `users`. The original migration removed
//      PocketBase's default avatar field as an unused leftover; now it is the
//      real one. Small on purpose (2 MB, one file, JPEG/PNG/WebP): these are
//      family portraits shown at 46-140 px, and a phone camera's 12 MP original
//      would cost the elderly user's mobile data on every roster read.
//
//   2. `email_changes` holds a pending move of the sign-in address, proven by a
//      code mailed to the NEW address (pb_hooks/email_change.pb.js). The
//      address IS the credential here — there is no password to fall back on —
//      so an unverified change would be a way to lock yourself out of your own
//      account with a typo, permanently and silently.
//
// Which fields the owner may actually write is enforced in pb_hooks/users.pb.js.
migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users")

    users.fields.add(
      new FileField({
        name: "avatar",
        maxSelect: 1,
        maxSize: 2097152,
        mimeTypes: ["image/jpeg", "image/png", "image/webp"],
        // Served to lists and to the call screen; the originals are never shown.
        thumbs: ["100x100", "300x300"],
        protected: false,
      }),
    )

    app.save(users)

    // ---- email_changes ------------------------------------------------------
    const changes = new Collection({
      type: "base",
      name: "email_changes",
      fields: [
        {
          type: "relation",
          name: "user",
          required: true,
          collectionId: users.id,
          // A deleted account leaves no half-finished address change behind.
          cascadeDelete: true,
          maxSelect: 1,
        },
        { type: "text", name: "newEmail", required: true, max: 255 },
        // The code is stored hashed, like any other credential: whoever can read
        // this table must not be able to complete somebody's address change.
        { type: "text", name: "codeHash", required: true, max: 128 },
        { type: "number", name: "attempts", required: false },
        // Unix seconds, not date fields: the hook compares them in plain
        // JavaScript, and a number needs no agreement about formats or zones
        // between the migration, the JSVM and the client.
        { type: "number", name: "sentAt", required: true },
        { type: "number", name: "expiresAt", required: true },
        { type: "autodate", name: "created", onCreate: true },
        { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
      ],

      // Entirely hook-owned. No client may read a pending change (the code hash
      // and the target address are both in it), create one directly, or delete
      // one to dodge the rate limit — every route goes through
      // pb_hooks/email_change.pb.js, whose $app calls bypass these rules.
      listRule: null,
      viewRule: null,
      createRule: null,
      updateRule: null,
      deleteRule: null,
    })
    app.save(changes)

    // Both hook queries look a pending change up by its owner.
    changes.addIndex("idx_email_changes_user", false, "user", "")
    app.save(changes)
  },
  (app) => {
    try {
      app.delete(app.findCollectionByNameOrId("email_changes"))
    } catch (err) {
      // already gone
    }
    try {
      const users = app.findCollectionByNameOrId("users")
      users.fields.removeByName("avatar")
      app.save(users)
    } catch (err) {
      // already gone
    }
  },
)
