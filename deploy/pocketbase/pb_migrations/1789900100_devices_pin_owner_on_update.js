/// <reference path="../pb_data/types.d.ts" />

// A device row can no longer be given away.
//
// devices.updateRule was `user = @request.auth.id`. A rule is evaluated against
// the record as it is STORED, so that only says "you may edit rows that are
// yours" — it says nothing about what you turn them into. An owner could PATCH
// {"user": "<someone else's uid>"} on their own row, and from then on the push
// fan-out (pb_hooks/calls.pb.js finds devices by `user`) would ring THEIR phone
// for every call meant for that person: a silent wiretap on who calls the
// primary user and when, and a way to answer in their place.
//
// The create rule already pins the new value (`@request.body.user =
// @request.auth.id`); this does the same for updates. `:isset = false` keeps a
// partial PATCH that does not mention `user` working, and the shipped client —
// which always sends its own uid in the upsert body (DeviceRepo.upsert) —
// satisfies the second branch. Nothing legitimate changes.
migrate(
  (app) => {
    const devices = app.findCollectionByNameOrId("devices")
    devices.updateRule =
      "user = @request.auth.id && (@request.body.user:isset = false || @request.body.user = @request.auth.id)"
    app.save(devices)
  },
  (app) => {
    const devices = app.findCollectionByNameOrId("devices")
    devices.updateRule = "user = @request.auth.id"
    app.save(devices)
  },
)
