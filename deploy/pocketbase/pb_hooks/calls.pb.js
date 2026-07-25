/// <reference path="../pb_data/types.d.ts" />

// Server-side authority for the call state machine — the PocketBase
// replacement for the Firestore rules' legalTransition() plus the
// sweepStaleCalls scheduled function.

// Reject illegal call-state changes before they are persisted.
//
// This is what makes a hijacked or buggy client unable to corrupt a call:
// accepting an already-ended call, resurrecting a terminal one, or swapping
// who the participants are. It also gives the caller a typed 400 instead of a
// silent no-op.
//
// IMPORTANT: everything this handler needs must be declared INSIDE it.
// PocketBase runs hook callbacks in a pool of separate goja runtimes, so
// top-level `const`s in this file are NOT in scope here — referencing one is an
// undefined-variable throw at call time, which surfaces to the client as a
// confusing 400 on every state change. (Learned the hard way; see verify.sh.)
onRecordUpdateRequest((e) => {
  const LEGAL_TRANSITIONS = {
    ringing: ["accepted", "declined", "cancelled", "missed"],
    accepted: ["ended"],
    // declined / cancelled / missed / ended are terminal: no way out.
  }

  const previous = e.record.original()
  const from = previous.get("state")
  const to = e.record.get("state")

  // Participants are fixed for the life of the call.
  const immutable = ["callerId", "calleeId"]
  for (let i = 0; i < immutable.length; i++) {
    const field = immutable[i]
    if (e.record.get(field) !== previous.get(field)) {
      throw new BadRequestError("call " + field + " is immutable")
    }
  }

  if (to !== from) {
    const allowed = LEGAL_TRANSITIONS[from] || []
    if (allowed.indexOf(to) === -1) {
      throw new BadRequestError(
        "illegal call transition " + from + " -> " + to,
      )
    }
  }

  e.next()
}, "calls")

// ---------------------------------------------------------------- push fan-out
//
// Replaces the Firestore triggers onCallCreated / onCallEnded. The actual
// sending lives in /opt/freecaller/push.py, because PocketBase's JS runtime can
// only sign HS256 JWTs while APNs needs ES256 and FCM v1 needs RS256.
//
// The job is handed over as a temp FILE, not argv (device tokens would show up
// in `ps`) and not stdin (Cmd.stdin is a Go io.Reader that JS cannot build).
//
// Both handlers are self-contained: no shared top-level helpers, because hook
// callbacks run in separate goja runtimes and would not see them.

// A new ringing call: wake every one of the callee's devices.
onRecordAfterCreateSuccess((e) => {
  if (e.record.get("state") === "ringing") {
    const calleeId = e.record.get("calleeId")

    const devices = $app.findRecordsByFilter(
      "devices",
      "user = {:uid}",
      "",
      20,
      0,
      { uid: calleeId },
    )

    if (devices.length === 0) {
      console.log("no devices registered for callee " + calleeId)
    } else {
      const job = {
        kind: "ring",
        call: {
          callId: e.record.id,
          callerId: e.record.get("callerId"),
          callerName: e.record.get("callerName"),
          callerPhone: e.record.get("callerPhone"),
          // FCM data values must be strings.
          video: e.record.get("isVideo") ? "true" : "false",
        },
        devices: devices.map((d) => ({
          id: d.id,
          platform: d.get("platform"),
          voipToken: d.get("voipToken"),
          fcmToken: d.get("fcmToken"),
        })),
      }

      const jobPath = "/var/lib/freecaller/job-ring-" + e.record.id + ".json"
      try {
        $os.writeFile(jobPath, JSON.stringify(job), 0o600)
        const out = toString(
          $os.cmd("python3", "/opt/freecaller/push.py", "--job", jobPath).output(),
        )
        console.log("ring push " + e.record.id + ": " + out)

        // Prune tokens the provider says are dead, so we stop pushing to phones
        // that no longer exist. Only unambiguous signals set this flag.
        const parsed = JSON.parse(out)
        ;(parsed.results || []).forEach((r) => {
          if (r.unregistered && r.deviceId) {
            try {
              $app.delete($app.findRecordById("devices", r.deviceId))
              console.log("pruned dead device " + r.deviceId)
            } catch (err) {
              console.log("could not prune " + r.deviceId + ": " + err)
            }
          }
        })
      } catch (err) {
        // A push failure must never roll back the call record — the caller's
        // own ring timer and the sweep below remain the safety net.
        console.log("ring push FAILED for " + e.record.id + ": " + err)
      } finally {
        try {
          $os.remove(jobPath)
        } catch (err) {
          // best effort
        }
      }
    }
  }

  e.next()
}, "calls")

// A call that stopped ringing before it was answered: tell the callee's devices
// to drop the ring, or it keeps ringing to the 45s timeout. `declined` is the
// callee's own action, so their ring is already gone — skip it.
onRecordAfterUpdateSuccess((e) => {
  const previous = e.record.original()
  const from = previous.get("state")
  const to = e.record.get("state")

  if (from === "ringing" && (to === "cancelled" || to === "missed")) {
    const calleeId = e.record.get("calleeId")

    const devices = $app.findRecordsByFilter(
      "devices",
      "user = {:uid}",
      "",
      20,
      0,
      { uid: calleeId },
    )

    if (devices.length > 0) {
      const job = {
        kind: "cancel",
        call: { callId: e.record.id },
        devices: devices.map((d) => ({
          id: d.id,
          platform: d.get("platform"),
          voipToken: d.get("voipToken"),
          fcmToken: d.get("fcmToken"),
        })),
      }

      const jobPath = "/var/lib/freecaller/job-cancel-" + e.record.id + ".json"
      try {
        $os.writeFile(jobPath, JSON.stringify(job), 0o600)
        const out = toString(
          $os.cmd("python3", "/opt/freecaller/push.py", "--job", jobPath).output(),
        )
        console.log("cancel push " + e.record.id + ": " + out)
      } catch (err) {
        console.log("cancel push FAILED for " + e.record.id + ": " + err)
      } finally {
        try {
          $os.remove(jobPath)
        } catch (err) {
          // best effort
        }
      }
    }
  }

  e.next()
}, "calls")

// Fallback authority for missed calls. The caller's own ring timer normally
// writes `missed`, but if the caller crashed or lost the network the record
// would dangle in `ringing` forever — and the callee's UI trusts the record.
//
// Cron granularity is one minute, which is coarser than the 45s ring timeout;
// that is deliberate. This is the janitor, not the primary timeout.
cronAdd("sweepStaleCalls", "*/1 * * * *", () => {
  const now = new Date().toISOString().replace("T", " ")

  const stale = $app.findRecordsByFilter(
    "calls",
    'state = "ringing" && ringExpiresAt != "" && ringExpiresAt < {:now}',
    "",
    200,
    0,
    { now: now },
  )

  for (let i = 0; i < stale.length; i++) {
    const record = stale[i]
    record.set("state", "missed")
    record.set("endedAt", now)
    $app.save(record)
  }

  if (stale.length > 0) {
    console.log("swept " + stale.length + " stale ringing call(s) to missed")
  }
})
