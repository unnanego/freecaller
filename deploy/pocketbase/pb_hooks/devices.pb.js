/// <reference path="../pb_data/types.d.ts" />

// One physical phone owns exactly one device record.
//
// A phone that signs into another account must stop ringing for the account it
// left. The client unregisters on sign-out, but that is a best-effort call it
// cannot always make (crash, reinstall onto a restored backup, sign-out while
// offline). When it doesn't happen, the stale row still holds a LIVE push token
// — the same shape as the phantom-ring bug on Firebase, where a device kept
// receiving calls for an account nobody had signed out of.
//
// Two things identify the phone, and BOTH have to take over on registration:
//
//   deviceId — a UUID the client mints on first launch and keeps in
//     shared_preferences. Stable while the app stays installed; a reinstall
//     wipes the container and mints a fresh one, so the same phone comes back
//     looking brand new.
//
//   the push token — issued by APNs/FCM per device+bundle. An iOS PushKit token
//     routinely survives a reinstall unchanged, which is exactly the case
//     deviceId misses: two rows, two deviceIds, one physical phone, one live
//     token. The fan-out in calls.pb.js rings every row it finds for the callee,
//     so the phone rings for whichever account it USED to be signed into as
//     well as the one it is on now.
//
// So the newest registration wins on both keys. The unique index from the
// migration is the backstop for deviceId; this is what keeps it from simply
// 400-ing the new owner.
//
// IMPORTANT: everything each handler needs is declared INSIDE it — including
// the token sweep, which is why it appears twice. Hook callbacks run in a pool
// of separate goja runtimes and cannot see file-level declarations; reaching
// for one is an undefined-variable throw at call time. (Learned the hard way;
// see the same warning in calls.pb.js.)

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

  // Same phone, new deviceId: claim the token back off whoever still holds it.
  // Empty tokens are skipped — each platform fills only its own field, and
  // matching on "" would delete every row belonging to the other one.
  const fields = ["voipToken", "fcmToken"]
  for (let f = 0; f < fields.length; f++) {
    const token = String(e.record.get(fields[f]) || "")
    if (!token) continue

    const holders = $app.findRecordsByFilter(
      "devices",
      fields[f] + " = {:token}",
      "",
      20,
      0,
      { token: token },
    )

    for (let i = 0; i < holders.length; i++) {
      if (holders[i].id === e.record.id) continue
      $app.delete(holders[i])
      console.log(
        "dropped stale device " + holders[i].id + " (user " +
          holders[i].get("user") + "): its " + fields[f] +
          " now belongs to deviceId " + deviceId,
      )
    }
  }

  e.next()
}, "devices")

// The same token sweep, for a registration that lands as an UPDATE.
//
// The client only updates when it already owns a row for this user+deviceId, so
// the deviceId takeover has nothing to do here — but the token being written may
// still be one a stale row from a previous install holds, and that row is what
// would ring. Sweeping only on create would leave it in place.
onRecordUpdateRequest((e) => {
  const fields = ["voipToken", "fcmToken"]

  for (let f = 0; f < fields.length; f++) {
    const token = String(e.record.get(fields[f]) || "")
    if (!token) continue

    const holders = $app.findRecordsByFilter(
      "devices",
      fields[f] + " = {:token}",
      "",
      20,
      0,
      { token: token },
    )

    for (let i = 0; i < holders.length; i++) {
      if (holders[i].id === e.record.id) continue
      $app.delete(holders[i])
      console.log(
        "dropped stale device " + holders[i].id + " (user " +
          holders[i].get("user") + "): its " + fields[f] +
          " now belongs to deviceId " + e.record.get("deviceId"),
      )
    }
  }

  e.next()
}, "devices")
