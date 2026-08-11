/// <reference path="../pb_data/types.d.ts" />

// A place for a phone to say what it just did, when nobody can read its logs.
//
// The audio-route bugs on Android only reproduce on the phone that has them, and
// that phone belongs to the primary user — in another country, never on a cable,
// and updated only through Play. Android's own log is therefore unreachable, and
// Dart's log() is compiled out of release builds anyway. Without a channel like
// this, every attempt at a fix costs a Play release and a phone call, and comes
// back with "still not working" and nothing else.
//
// So: write-only from the client, read by a superuser (tools/diagnostics.mjs).
// Deliberately not a relation to `users` — a diagnostic outlives the account it
// came from, and a cascading delete would take the evidence with it (same
// reasoning as `reports`).
migrate(
  (app) => {
    const diagnostics = new Collection({
      type: "base",
      name: "diagnostics",
      fields: [
        { type: "text", name: "userUid", required: true, max: 255 },
        { type: "text", name: "callId", max: 64 },
        { type: "text", name: "platform", max: 32 },
        { type: "text", name: "event", required: true, max: 64 },
        // The whole report as one human-readable line: phone model, API level,
        // what was asked for, the audio state before and after, and which branch
        // ran. One string because it is read by eye, in a terminal, by someone
        // who cannot touch the device.
        { type: "text", name: "detail", max: 2000 },
        { type: "autodate", name: "created", onCreate: true },
      ],

      // Anyone signed in may file one for themselves; nothing can read them
      // back, and nothing can edit or delete one.
      createRule:
        '@request.auth.id != "" && @request.body.userUid = @request.auth.id',
      listRule: null,
      viewRule: null,
      updateRule: null,
      deleteRule: null,
    })
    app.save(diagnostics)

    // Every read is "the newest first", and the purge cron in
    // pb_hooks/diagnostics.pb.js filters on the same field.
    diagnostics.addIndex("idx_diagnostics_created", false, "created", "")
    app.save(diagnostics)
  },
  (app) => {
    try {
      app.delete(app.findCollectionByNameOrId("diagnostics"))
    } catch (err) {
      // already gone
    }
  },
)
