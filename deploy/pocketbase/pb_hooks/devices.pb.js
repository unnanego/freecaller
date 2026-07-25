/// <reference path="../pb_data/types.d.ts" />

// One physical install owns exactly one device record.
//
// A phone that signs into another account must stop ringing for the account it
// left. The client unregisters on sign-out, but that is a best-effort call it
// cannot always make (crash, reinstall onto a restored backup, sign-out while
// offline). When it doesn't happen, the stale row still holds a LIVE push token
// — the same shape as the phantom-ring bug on Firebase, where a device kept
// receiving calls for an account nobody had signed out of.
//
// So registration takes over: a create for a deviceId that already exists
// deletes the previous row first, whoever it belonged to. The unique index from
// the migration is the backstop; this is what keeps it from simply 400-ing the
// new owner.
//
// Everything the handler needs is declared inside it: hook callbacks run in
// separate goja runtimes and cannot see file-level variables.
onRecordCreateRequest((e) => {
  const deviceId = String(e.record.get("deviceId") || "")

  if (deviceId) {
    const existing = $app.findRecordsByFilter(
      "devices",
      "deviceId = {:deviceId}",
      "",
      10,
      0,
      { deviceId: deviceId },
    )

    for (let i = 0; i < existing.length; i++) {
      $app.delete(existing[i])
      console.log(
        "device " + deviceId + " re-registered: dropped previous owner " +
          existing[i].get("user"),
      )
    }
  }

  e.next()
}, "devices")
