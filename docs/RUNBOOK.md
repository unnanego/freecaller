# Runbook

## LiveKit free-tier cap (the one failure mode to watch)

The Build tier allows **5000 participant-minutes/month** (a 1:1 call burns
2/min, so ≈83 minutes of calling per day) and **fails closed**: when
exhausted, new connections are refused until the month rolls over — grandma's
call just won't connect.

Video also consumes the **50 GB/month egress** allowance: 1:1 video at 540p
is roughly 0.25–0.3 GB/hour per subscriber, so ~150+ hours/month — the
minute cap will always bite first.

- Set a usage alert at ~70% in the LiveKit Cloud dashboard.
- **Escape hatch** (pre-planned, ~$6/month): self-host LiveKit OSS on a
  small VPS (Hetzner/DO) with its embedded TURN enabled. Client code is
  identical — only `LIVEKIT_URL` + key secrets in the functions config
  change. Open UDP 50000–60000 and 443/TCP (TURN/TLS), TLS cert via
  Let's Encrypt.
- Alternative if you'd rather stay managed: Agora (~$1 per 1000 minutes
  overage) — but that's a client-code change, unlike self-hosting.

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
