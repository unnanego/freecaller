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
  `apns.env: "production"` in `/etc/freecaller/push.json` on the PocketBase
  host. Symptom of mismatch: pushes "succeed" (or 400 BadDeviceToken) but
  never arrive.
- Server-side push log: `journalctl -u pocketbase | grep "ring push"` — the
  hook logs push.py's result per call, including which device tokens were
  pruned as dead.
- Android not ringing from terminated: check `POST_NOTIFICATIONS` and
  full-screen-intent grants, and OEM battery optimization (Samsung/Xiaomi
  kill-lists — exempt the app).

## Sign-in codes don't arrive

Sign-in is an emailed one-time code, so mail delivery IS authentication. The
failure is silent by design: `POST /api/collections/users/request-otp` answers
200 with an otpId even for an address that has no account, so a 200 proves
nothing.

1. `journalctl -u pocketbase | grep -i mail` — SMTP errors surface here.
2. Re-run [`deploy/pocketbase/configure-mail.sh`](../deploy/pocketbase/configure-mail.sh);
   it ends by sending a real test message.
3. Check the recipient's spam folder. Mail must go out through the host that
   owns the domain's MX/SPF record (REG.RU), or it gets filtered.
4. The code is valid 15 minutes and single-use. A second request invalidates
   nothing, but the user must type the code from the LATEST email.

## App Store review accounts

Provision **three** review accounts (`deploy/pocketbase/roster.example.json`
has them), linked only to each other so no real family member's name or number
is exposed. Three because the 5.1.1(v) account-deletion demo destroys the
account it is performed on — one is spent, two survive.

The reviewer does not get a mailbox. Their codes are **pinned to constants** by
`pb_hooks/review_otp.pb.js`, which reads `/etc/freecaller/review-otp.json`
(template: `review-otp.json.example`, install root:pocketbase 640). They type
the email and then the code from the review notes, through the same activation
screen a real user sees.

Two things to remember:

- For a listed account the **emailed code stops working** — only the pinned one
  does. Don't debug a review account through its inbox.
- **Delete `/etc/freecaller/review-otp.json` when review is over.** The hook
  reads it per request, so removing the file is the off switch — no redeploy,
  no restart. Then delete whatever is left of the accounts
  (`node tools/admin.mjs list`, then the PB dashboard) and re-run `apply`
  before the next submission with fresh codes.

## Adding/removing a family member

`tools/admin.mjs add-user` + `link` (PocketBase is loopback-only, so tunnel
 first: `ssh -N -L 8090:127.0.0.1:8090 root@<server>`). The roster change
propagates automatically: her app re-syncs contacts on next foreground,
which rewrites the Siri App-Group snapshot and INVocabulary — the new name
becomes speakable without an app update.

## Stale calls

The `sweepStaleCalls` cron in `deploy/pocketbase/pb_hooks/calls.pb.js` runs
every minute and flips `ringing` records past `ringExpiresAt` to `missed` —
it covers a caller that crashed or went offline. If calls ever look stuck,
check `journalctl -u pocketbase` first.

## Releasing

Bump the **version** in pubspec.yaml — the last component, every submission:
1.1.0 → 1.1.1. That is the number that names the release everywhere. The `+N`
behind it is Android's versionCode, which Play requires to be strictly greater
than anything ever uploaded to the track, so it moves too — but it is a counter,
not the release name.

```
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
xcrun altool --upload-app --type ios -f build/ios/ipa/freecaller.ipa \
  --apiKey R8JSXTZRG7 --apiIssuer 9361f0c2-10ac-409e-bc72-8e29c63607ed
flutter build appbundle --release      # Play upload is manual, Console UI
```

**Always pass `--export-options-plist`.** Without it Flutter writes its own
export options with `manageAppVersionAndBuildNumber` set, and Xcode rewrites
CFBundleVersion during export to whatever App Store Connect will accept next:
an archive built as 13 was delivered to the store as 14, so the store, the git
tag and the rejection email all disagreed. `ios/ExportOptions.plist` is the same
file with that switch off.

Verify what you are about to ship rather than what you meant to:

```
unzip -p build/ios/ipa/freecaller.ipa Payload/Runner.app/Info.plist | plutil -p - | grep -i version
```

After a plugin upgrade, Android may fail with `Cannot access class` errors from
inside a plugin's own module (livekit_client did on 2.8.1 → 2.10.0). That is
stale Kotlin incremental state, not an incompatibility: delete `build/<plugin>`
and build again.
