/// <reference path="../pb_data/types.d.ts" />

// Give a device record the identity its Firestore ancestor had for free.
//
// The old path was users/{uid}/devices/{deviceId}, where deviceId is a per-
// install UUID the client mints on first launch and keeps in shared_preferences.
// The doc id WAS the install identity, so re-registering was a merge-set.
//
// PocketBase generates its own 15-char ids, so the install id has to be a field.
// (Widening the id pattern the way `calls` did would work too, but a device is
// not addressed by id anywhere — the push fan-out finds devices by `user` — so a
// field with an index is the simpler shape.)
//
// The index is unique across the WHOLE collection, not per user: one physical
// install must never hold two registrations, or a phone that changed accounts
// keeps ringing for the account it left. That was a real bug on Firebase; see
// pb_hooks/devices.pb.js for the takeover that enforces the other half of it.
migrate(
  (app) => {
    const devices = app.findCollectionByNameOrId("devices")

    devices.fields.add(
      new TextField({ name: "deviceId", required: true, max: 64 }),
    )
    app.save(devices)

    // Rows that predate the field have an empty deviceId, and a unique index
    // over several empty strings will not build. Backfill first — the record id
    // is already unique, and any such row is a test leftover whose real install
    // id is unknowable anyway (its next registration takes it over).
    const existing = app.findRecordsByFilter("devices", "deviceId = ''", "", 500, 0)
    for (let i = 0; i < existing.length; i++) {
      existing[i].set("deviceId", "legacy-" + existing[i].id)
      app.save(existing[i])
    }
    if (existing.length > 0) {
      console.log("backfilled deviceId on " + existing.length + " device record(s)")
    }

    devices.addIndex("idx_devices_deviceid", true, "deviceId", "")
    app.save(devices)
  },
  (app) => {
    const devices = app.findCollectionByNameOrId("devices")
    devices.removeIndex("idx_devices_deviceid")
    devices.fields.removeByName("deviceId")
    app.save(devices)
  },
)
