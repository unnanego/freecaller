/// <reference path="../pb_data/types.d.ts" />

// Server-side authority for the call state machine — the PocketBase
// replacement for the Firestore rules' legalTransition() plus the
// sweepStaleCalls scheduled function.

// A new call is only what the SERVER says it is.
//
// The create rule pins `callerId` to the signed-in account and nothing else, and
// everything else in the body used to be taken on trust — including the two
// fields that matter most. `callerName` and `callerPhone` go verbatim into the
// push, and CallKit / Siri READ THEM ALOUD to a blind user: whoever could sign
// in (an App Review account, an invited stranger) could ring him announcing
// themselves as his daughter. So:
//
//   callerName / callerPhone — overwritten from the caller's own account. What
//       the client sent is ignored, not compared: shipped builds send the same
//       values they read from that very record, so nothing legitimate changes.
//
//   calleeId — must be a real account, and not the caller. It is deliberately
//       NOT required to be in the caller's `contacts`: the Contacts screen also
//       offers everyone discovered through the address book
//       (/api/freecaller/match-contacts), and those people are callable without
//       ever being in the roster relation. Requiring the relation would break
//       calling for exactly the accounts that found each other by phone number.
//
//   ringExpiresAt — now + 45s by the server's clock. The sweep below trusts this
//       field, and a client value is whatever the client's clock (or author)
//       wanted it to be: a year from now, or empty, both of which the sweep
//       would never touch.
//
//   id — must be a UUID (8-4-4-4-12 hex). It doubles as the CallKit call UUID,
//       and iOS DROPS a VoIP push whose callId does not parse as one: the app
//       then fails to report a call for a push it received, which iOS answers
//       by killing it and, repeated, by throttling its pushes altogether. The
//       field's own pattern stays wide (changing it could invalidate records
//       that already exist); this only gates NEW calls.
//
// All of this applies to app accounts only. A superuser (tools/fakecall.mjs,
// tools/faketalk.mjs, the dashboard) is not a `users` record, has no profile
// to copy a name from, and keeps choosing its own name and ring window — but
// the UUID rule holds for everyone, because the phone at the other end does
// not care who wrote the record.
//
// Everything is declared inside the handler — see the warning further down.
onRecordCreateRequest((e) => {
  const RING_SECONDS = 45
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  if (!UUID.test(String(e.record.id || ""))) {
    throw new BadRequestError("call id must be a UUID")
  }

  const auth = e.auth
  const isAppUser = !!auth && auth.collection().name === "users"

  if (isAppUser) {
    const calleeId = String(e.record.get("calleeId") || "")
    if (!calleeId || calleeId === auth.id) {
      throw new BadRequestError("cannot call yourself")
    }
    try {
      $app.findRecordById("users", calleeId)
    } catch (err) {
      throw new BadRequestError("unknown callee")
    }

    // Read the account fresh rather than off the token's copy: a name changed
    // a minute ago should be the name that is announced.
    const me = $app.findRecordById("users", auth.id)
    e.record.set("callerId", auth.id)
    e.record.set("callerName", String(me.get("displayName") || ""))
    e.record.set("callerPhone", String(me.get("phone") || ""))

    e.record.set(
      "ringExpiresAt",
      new Date(Date.now() + RING_SECONDS * 1000).toISOString().replace("T", " "),
    )

    // A record is born ringing and with nothing else decided yet.
    e.record.set("state", "ringing")
    e.record.set("acceptedAt", "")
    e.record.set("endedAt", "")
    e.record.set("endedBy", "")
  }

  e.next()
}, "calls")

// Reject illegal call-state changes before they are persisted.
//
// This is what makes a hijacked or buggy client unable to corrupt a call:
// accepting an already-ended call, resurrecting a terminal one, or swapping
// who the participants are. It also gives the caller a typed 400 instead of a
// silent no-op.
//
// Two questions are asked of every change: is the transition legal, and is it
// THIS participant's to make. The second one used to be missing — the update
// rule only says "a participant", so the caller could write `accepted` on
// their own outgoing call (and be handed a room with a callee who never
// answered), and the callee could mark a call they were ignoring as `missed`
// or `cancelled`. Ownership, mirrored from the client's own table
// (CallEngine._ownedTerminalState):
//
//   ringing  -> accepted | declined    the CALLEE answers or refuses
//   ringing  -> cancelled | missed     the CALLER gives up or times out
//   accepted -> ended                  either side hangs up
//
// Who is asked only of app accounts. A write with no `users` auth record — the
// sweep below (which saves through $app and never reaches a request hook
// anyway), tools/endcall.mjs as a superuser, the dashboard — is the server
// acting on its own authority and only has to be a legal transition.
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
  // Which participant owns each target state. `ended` is absent: either may.
  const OWNER = {
    accepted: "calleeId",
    declined: "calleeId",
    cancelled: "callerId",
    missed: "callerId",
  }

  const previous = e.record.original()
  const from = previous.getString("state")
  const to = e.record.getString("state")

  const auth = e.auth
  const isAppUser = !!auth && auth.collection().name === "users"

  // Participants are fixed for the life of the call — for everyone.
  const immutable = ["callerId", "calleeId"]
  // …and for app accounts so is everything the server decided at creation.
  // The name and number are what the callee's phone announces and what the
  // history list shows afterwards; the expiry is what the sweep trusts.
  // `isVideo` is deliberately NOT here: the app flips it mid-call (setVideo)
  // and the peer follows through its watch. getString() so that a date compares
  // by value — two DateTime objects are never `===`.
  if (isAppUser) {
    immutable.push("callerName", "callerPhone", "ringExpiresAt")
  }
  for (let i = 0; i < immutable.length; i++) {
    const field = immutable[i]
    if (e.record.getString(field) !== previous.getString(field)) {
      throw new BadRequestError("call " + field + " is immutable")
    }
  }

  // `endedBy` is a claim about who hung up, shown in the history; nobody gets
  // to make it on someone else's behalf. Only checked when it changes, so a
  // partial PATCH that leaves it alone is never affected.
  if (isAppUser) {
    const endedBy = e.record.getString("endedBy")
    if (
      endedBy !== previous.getString("endedBy") &&
      endedBy !== "" &&
      endedBy !== auth.id
    ) {
      throw new BadRequestError("endedBy must be the signed-in account")
    }
  }

  if (to === from) {
    return e.next()
  }

  const allowed = LEGAL_TRANSITIONS[from] || []
  if (allowed.indexOf(to) === -1) {
    throw new BadRequestError("illegal call transition " + from + " -> " + to)
  }

  if (isAppUser && OWNER[to] && previous.getString(OWNER[to]) !== auth.id) {
    throw new ForbiddenError(
      "only the " + (OWNER[to] === "calleeId" ? "callee" : "caller") +
        " may move a call to " + to,
    )
  }

  // ---- compare-and-swap ------------------------------------------------------
  //
  // `previous` was read when the request arrived and the save happens in
  // e.next(), so two writers racing out of `ringing` — the callee accepting in
  // the same instant the caller cancels — both pass every check above, and the
  // later save wins. When that is the accept, the record says `accepted`, the
  // caller has already torn down believing it cancelled, and the callee sits in
  // an empty room.
  //
  // So the transition is claimed first, with one guarded UPDATE that SQLite
  // executes atomically: it only matches while the state is still the one this
  // request was judged against. Whoever gets there second matches nothing and
  // is told 400 — which is the answer the client is built for (CallRepo.accept
  // rethrows it; the caller's teardown re-reads and closes an `accepted` call
  // with `ended`). e.next() then saves the full record as before, writing the
  // same state again plus the other fields, and fires the after-update hook
  // with `original()` still saying `ringing`, so the cancel push is unaffected.
  //
  // Deliberately NOT done as runInTransaction + `e.app = txApp`: if that
  // reassignment does not take in this JSVM, e.next() saves on the outer app
  // while the transaction holds PocketBase's single write connection — a
  // deadlock on every call, in production. A guarded UPDATE cannot do that.
  //
  // The guard machinery itself fails OPEN (logs, falls back to the unguarded
  // behaviour this hook always had): a surprise in the query-builder API must
  // not turn into "nobody can answer a call".
  let claimed = false
  let lost = false
  try {
    const result = $app
      .db()
      .newQuery(
        "UPDATE calls SET state = {:to} WHERE id = {:id} AND state = {:from}",
      )
      .bind({ to: to, id: e.record.id, from: from })
      .execute()
    const affected = Number(result.rowsAffected())
    if (affected === 0) {
      lost = true
    } else if (affected > 0) {
      claimed = true
    }
  } catch (err) {
    console.log("call " + e.record.id + ": transition guard unavailable: " + err)
  }

  if (lost) {
    throw new BadRequestError(
      "illegal call transition: the call is no longer " + from,
    )
  }

  try {
    return e.next()
  } catch (err) {
    // The save was refused after the state had been claimed (a malformed date
    // in the same body, say). Hand the state back, guarded the same way, so a
    // rejected request leaves no half-applied transition behind it.
    if (claimed) {
      try {
        $app
          .db()
          .newQuery(
            "UPDATE calls SET state = {:from} WHERE id = {:id} AND state = {:to}",
          )
          .bind({ to: to, id: e.record.id, from: from })
          .execute()
      } catch (err2) {
        console.log("call " + e.record.id + ": could not undo claim: " + err2)
      }
    }
    throw err
  }
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
// The send runs INSIDE the request that created (or cancelled) the call — the
// JSVM has no way to hand work to a background thread — so how long a caller
// waits on "create call" is decided by push.py: it sends to all devices at
// once under one overall deadline (~8s) and arms a hard self-kill a few seconds
// after that. Nothing here needs its own timeout as long as that holds; if you
// ever swap the helper, keep that contract.
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

  // A ring can only still be on a screen while the call is young. The sweep
  // also closes OLD dangling records (its two-minute and legacy-expiry nets),
  // and a cancel is a VoIP push: on iOS every one of those wakes the app, which
  // must then answer to CallKit for it. Waking the primary user's phone over a
  // call from last month helps nobody, so anything older than five minutes is
  // closed silently. Unparseable `created` -> treated as young, i.e. the old
  // behaviour.
  const createdMs = Date.parse(e.record.getString("created").replace(" ", "T"))
  const young = isNaN(createdMs) || Date.now() - createdMs < 5 * 60 * 1000

  if (young && from === "ringing" && (to === "cancelled" || to === "missed")) {
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

// Fallback authority for calls nobody closed. The caller's own ring timer
// normally writes `missed`, and whoever hangs up writes `ended`, but a client
// that crashed or lost the network leaves the record dangling — and the other
// side's UI, the token endpoint and cold-start recovery all trust the record.
//
// Three nets, widest last:
//
//   1. ringing past its `ringExpiresAt` -> missed. The expiry is stamped by the
//      server at creation (see the create hook above), so for every call made
//      since then this is the real 45s window.
//   2. ringing and older than two minutes, WHATEVER ringExpiresAt says
//      -> missed. Records that predate the server stamp carry a client's value:
//      empty (the old filter skipped those outright) or arbitrarily far in the
//      future. `created` is the server's own autodate and cannot be argued with.
//      Side effect worth knowing: a superuser test call (tools/fakecall.mjs asks
//      for a 3-minute ring) is cut off here at two.
//   3. accepted and older than six hours -> ended. Nothing else ever closes an
//      `accepted` call both sides walked away from, and while it stays open the
//      token endpoint keeps minting room tokens for it. Six hours is far past
//      any real family call and well short of "forever".
//
// Both writes are legal transitions (ringing -> missed, accepted -> ended), and
// they go through $app.save(), so the after-update hook above still runs and a
// swept ring still gets its cancel push exactly as before. No request hook is
// involved — there is no auth record here — so the who-may-do-what check does
// not apply to the janitor.
//
// Each record is re-read just before it is written: the list was fetched a
// moment ago, and a callee who answered in between must not have their call
// swept out from under them. (A re-read narrows that window to microseconds; it
// does not close it. The guarded UPDATE in the request hook does not help here
// because the full-record save below would still overwrite the state.)
//
// Cron granularity is one minute, which is coarser than the 45s ring timeout;
// that is deliberate. This is the janitor, not the primary timeout.
//
// Everything is declared inside the callback: cron callbacks run in their own
// goja runtime, like hooks, and see nothing declared at file level.
cronAdd("sweepStaleCalls", "*/1 * * * *", () => {
  const RINGING_MAX_AGE_MS = 2 * 60 * 1000
  const ACCEPTED_MAX_AGE_MS = 6 * 60 * 60 * 1000

  const stamp = (ms) => new Date(ms).toISOString().replace("T", " ")
  const nowMs = Date.now()
  const now = stamp(nowMs)

  const close = (filter, params, from, to) => {
    let found = []
    try {
      found = $app.findRecordsByFilter("calls", filter, "", 200, 0, params)
    } catch (err) {
      console.log("sweep: query failed (" + from + "): " + err)
      return 0
    }

    let closed = 0
    for (let i = 0; i < found.length; i++) {
      try {
        const record = $app.findRecordById("calls", found[i].id)
        if (record.getString("state") !== from) continue
        record.set("state", to)
        record.set("endedAt", now)
        $app.save(record)
        closed++
      } catch (err) {
        // One bad row must not stop the rest from being swept.
        console.log("sweep: could not close " + found[i].id + ": " + err)
      }
    }
    return closed
  }

  const missed = close(
    'state = "ringing" && ((ringExpiresAt != "" && ringExpiresAt < {:now}) || created < {:ringCutoff})',
    { now: now, ringCutoff: stamp(nowMs - RINGING_MAX_AGE_MS) },
    "ringing",
    "missed",
  )
  if (missed > 0) {
    console.log("swept " + missed + " stale ringing call(s) to missed")
  }

  const ended = close(
    'state = "accepted" && created < {:acceptedCutoff}',
    { acceptedCutoff: stamp(nowMs - ACCEPTED_MAX_AGE_MS) },
    "accepted",
    "ended",
  )
  if (ended > 0) {
    console.log("swept " + ended + " abandoned accepted call(s) to ended")
  }
})
