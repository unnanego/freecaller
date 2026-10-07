/// <reference path="../pb_data/types.d.ts" />

// The Apple Watch as a calling device of its own (docs/watch-plan.md).
//
// devices.platform gains "watchos". A watch registers its own PushKit VoIP
// token, and the push fan-out must send to it under the WATCH app's topic —
// APNs refuses a watch token pushed under the iPhone app's bundle id — so the
// sender has to be able to tell the two apart. ("ios" stays the iPhone; every
// shipped build keeps writing exactly what it writes today.)
//
// calls.answeredOn is the `deviceId` (the devices row's install id, not its
// record id) of the device that answered or declined. A callee with a phone
// AND a watch is rung on both, and once one of them picks up, the other has to
// stop. The phone app already notices on its own through its call watch, but a
// ringing watch has no such watch, and the cheap way to stop a ring is the
// cancel push — which must NOT go to the device that answered: on iOS a cancel
// push for a call that is up hangs it up. So the answering device names itself,
// and the cancel goes to everyone else. Empty = unknown (every build before
// this one): no answered-elsewhere push at all, exactly the old behaviour.
// pb_hooks/calls.pb.js owns who may set it, and when.
migrate(
  (app) => {
    const devices = app.findCollectionByNameOrId("devices")
    const platform = devices.fields.getByName("platform")
    platform.values = ["ios", "android", "watchos"]
    app.save(devices)

    const calls = app.findCollectionByNameOrId("calls")
    calls.fields.add(new TextField({ name: "answeredOn", max: 64 }))
    app.save(calls)
  },
  (app) => {
    const calls = app.findCollectionByNameOrId("calls")
    calls.fields.removeByName("answeredOn")
    app.save(calls)

    // Down-migrating with watch rows present would fail validation on them;
    // they are useless without the watch build anyway.
    const watches = app.findRecordsByFilter("devices", "platform = 'watchos'", "", 500, 0)
    for (let i = 0; i < watches.length; i++) app.delete(watches[i])

    const devices = app.findCollectionByNameOrId("devices")
    const platform = devices.fields.getByName("platform")
    platform.values = ["ios", "android"]
    app.save(devices)
  },
)
