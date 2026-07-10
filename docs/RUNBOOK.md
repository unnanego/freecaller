# Runbook

## LiveKit media server (self-hosted)

Runs on your VPS via `deploy/livekit/` (Docker Compose: livekit-server +
redis + caddy). Deploy/upgrade and firewall details are in that directory's
README.

- **If calls connect but have no audio/video**: almost always a firewall /
  port issue. Check that UDP 50000–60000 and 3478, and TCP 443 and 7881,
  are open on the VPS. `docker compose logs livekit` shows ICE failures.
- **Upgrade**: `docker compose pull && docker compose up -d`.
- **Capacity**: audio + family-scale video is trivial CPU; watch the VPS's
  monthly bandwidth instead (video ≈ 0.3 GB/hour per participant of egress).
- **Cert renewal** is automatic (Caddy). If TURN/TLS breaks after ~90 days,
  check Caddy logs and that port 80 was reachable for the renewal challenge.
- Managed fallback if you ever want off-box: LiveKit Cloud is a drop-in —
  only `LIVEKIT_URL` + the two key secrets change, no app code.

## Push debugging

- iOS device console: search `0xbaadca11` — means a VoIP push arrived and
  no CallKit call was reported. Must never happen (AppDelegate reports
  synchronously); repeated offenses get pushes throttled by iOS.
- Sandbox vs production APNs: TestFlight/App Store builds need
  `APNS_ENV=production` in `functions/.env`. Symptom of mismatch: pushes
  "succeed" (or 400 BadDeviceToken) but never arrive.
- Android not ringing from terminated: check `POST_NOTIFICATIONS` and
  full-screen-intent grants, and OEM battery optimization (Samsung/Xiaomi
  kill-lists — exempt the app).

## Adding/removing a family member

`tools/admin.ts add-user` + `link` (see SETUP.md §6). The roster change
propagates automatically: her app re-syncs contacts on next foreground,
which rewrites the Siri App-Group snapshot and INVocabulary — the new name
becomes speakable without an app update.

## Stale calls

`sweepStaleCalls` (every minute) flips `ringing` docs past `ringExpiresAt`
to `missed` — covers caller crash/offline. If calls ever look stuck in
Firestore, check that function's logs first.
