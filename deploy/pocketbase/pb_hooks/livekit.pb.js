/// <reference path="../pb_data/types.d.ts" />

// LiveKit room-token endpoint — replaces the `mintLiveKitToken` callable
// Cloud Function.
//
//   POST /api/freecaller/livekit-token   {"callId": "<uuid>"}
//   ->  {"token": "...", "url": "wss://...", "iceServers": [...]}
//
// Authorization lives here; crypto lives in /opt/freecaller/livekit_token.py
// (coturn's REST credential needs HMAC-SHA1, which the JS runtime cannot do).
//
// Everything the handler needs is declared inside it: hook callbacks run in
// separate goja runtimes and cannot see file-level variables.
routerAdd(
  "POST",
  "/api/freecaller/livekit-token",
  (e) => {
    const auth = e.auth
    if (!auth) {
      return e.json(401, { message: "Sign in required" })
    }

    let callId = ""
    try {
      const body = e.requestInfo().body
      callId = String(body.callId || "").trim()
    } catch (err) {
      return e.json(400, { message: "Malformed request body" })
    }
    if (!callId) {
      return e.json(400, { message: "callId is required" })
    }

    // Read the call directly (not through the API rules) so the checks below are
    // explicit and the failure reasons distinguishable.
    let call
    try {
      call = $app.findRecordById("calls", callId)
    } catch (err) {
      return e.json(404, { message: "Unknown call" })
    }

    if (call.get("callerId") !== auth.id && call.get("calleeId") !== auth.id) {
      return e.json(403, { message: "Not a participant of this call" })
    }

    // A token must only exist while the call could plausibly carry media. Once
    // it is ended/declined/missed, nobody may rejoin the room.
    const state = call.get("state")
    if (state !== "ringing" && state !== "accepted") {
      return e.json(409, { message: "Call is " + state })
    }

    // …and `state` alone is only as good as whoever last wrote it. A record
    // can read `ringing` or `accepted` long after both phones have gone — the
    // sweep in calls.pb.js closes those, but on a one-minute cron, and until it
    // does this endpoint would mint a fresh hour-long room token for a call
    // that ended yesterday. Same two limits as the sweep, measured on the
    // server's own `created` stamp. An unparseable date skips the check rather
    // than refusing a live call.
    const createdMs = Date.parse(call.getString("created").replace(" ", "T"))
    if (!isNaN(createdMs)) {
      const ageMs = Date.now() - createdMs
      const limitMs = state === "ringing" ? 2 * 60 * 1000 : 6 * 60 * 60 * 1000
      if (ageMs > limitMs) {
        return e.json(409, { message: "Call is stale" })
      }
    }

    // Per-participant job file: two participants mint concurrently for the same
    // call, so the path must not collide.
    const jobPath =
      "/var/lib/freecaller/job-lk-" + callId + "-" + auth.id + ".json"

    try {
      $os.writeFile(
        jobPath,
        JSON.stringify({ identity: auth.id, room: callId, ttlSeconds: 3600 }),
        0o600,
      )

      const raw = toString(
        $os
          .cmd("python3", "/opt/freecaller/livekit_token.py", "--job", jobPath)
          .output(),
      )
      const minted = JSON.parse(raw)

      if (!minted.token) {
        console.log("livekit token error for " + callId + ": " + raw)
        return e.json(500, { message: "Could not mint a room token" })
      }

      return e.json(200, minted)
    } catch (err) {
      console.log("livekit token FAILED for " + callId + ": " + err)
      return e.json(500, { message: "Could not mint a room token" })
    } finally {
      try {
        $os.remove(jobPath)
      } catch (err) {
        // best effort
      }
    }
  },
  $apis.requireAuth(),
)
