/// <reference path="../pb_data/types.d.ts" />

// Keep the diagnostics collection from becoming permanent.
//
// It exists to debug a phone nobody can reach with a cable (see the migration
// 1786406400_create_diagnostics.js), and a debug channel that quietly grows
// forever on a family VPS is its own small bug. Two weeks is long enough to
// cover a Play release, a phone call and a second attempt.
//
// Nothing else guards the size: the client writes one line per audio-route
// CHANGE, not per attempt, so a call produces one or two records.
const DIAGNOSTICS_TTL_DAYS = 14

cronAdd("purgeDiagnostics", "0 4 * * *", () => {
  const cutoff = new Date(Date.now() - DIAGNOSTICS_TTL_DAYS * 86400 * 1000)
    .toISOString()
    .replace("T", " ")

  let purged = 0
  // Bounded per run: a runaway client must not turn the janitor into the thing
  // that stalls the server. Whatever is left goes on the next night's run.
  const old = $app.findRecordsByFilter(
    "diagnostics",
    "created < {:cutoff}",
    "",
    2000,
    0,
    { cutoff: cutoff },
  )

  for (let i = 0; i < old.length; i++) {
    try {
      $app.delete(old[i])
      purged++
    } catch (err) {
      // Keep going; one bad row must not abort the sweep.
    }
  }

  if (purged > 0) {
    console.log("purged " + purged + " diagnostic record(s) older than " +
      DIAGNOSTICS_TTL_DAYS + " days")
  }
})
