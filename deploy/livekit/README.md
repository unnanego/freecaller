# Self-hosted LiveKit for Freecaller

Runs the open-source LiveKit media server (SFU + TURN) on your own VPS.
Handles 1:1 and group calls; the Flutter app and Cloud Functions are
identical to the managed-cloud path — only the URL and keys differ.

## Prerequisites

- A VPS with root + Docker + Docker Compose.
- A domain with two A records pointing at the VPS's public IP:
  - `livekit.YOURDOMAIN.com` (signaling, WSS)
  - `livekit-turn.YOURDOMAIN.com` (TURN/TLS)
- Firewall / security group open for:
  - **443/tcp** — WSS signaling + TURN/TLS (Caddy)
  - **7881/tcp** — WebRTC over TCP fallback
  - **3478/udp** — TURN/UDP
  - **50000-60000/udp** — WebRTC media
  - **80/tcp** — only during first cert issuance (Let's Encrypt HTTP challenge)

## Setup

```bash
# on the VPS, in this deploy/livekit directory
cp livekit.yaml.example livekit.yaml
cp caddy.yaml.example   caddy.yaml

# generate an API key/secret pair, paste into livekit.yaml under `keys:`
docker run --rm livekit/livekit-server generate-keys

# replace YOURDOMAIN in both livekit.yaml (turn.domain) and caddy.yaml
# then bring it up
docker compose up -d
docker compose logs -f livekit   # should log "starting LiveKit server"
```

Verify: `wss://livekit.YOURDOMAIN.com` should upgrade (a quick
`curl -i https://livekit.YOURDOMAIN.com` returns a LiveKit response, not a
cert error).

## Wire it into the app's backend

Point the Cloud Functions at this server (no app code changes):

```bash
cd ../../functions
firebase functions:secrets:set LIVEKIT_API_KEY      # the API key from generate-keys
firebase functions:secrets:set LIVEKIT_API_SECRET   # the secret
echo 'LIVEKIT_URL=wss://livekit.YOURDOMAIN.com' >> .env
firebase deploy --only functions
```

That's it — `mintLiveKitToken` now issues tokens for your server, and both
apps connect to it.

## Sizing

Audio + 1:1/small-group video for a family is trivial load — the smallest
VPS (1 vCPU / 1 GB) is plenty. Video is ~0.3 GB/hour per participant of
egress; watch your VPS bandwidth allowance, not CPU.

## Notes

- `livekit.yaml` holds the API secret and is gitignored — keep it only on
  the server (and the secret in Firebase secrets).
- For a second node later, LiveKit needs the shared Redis (already in the
  compose file) and a load balancer — not needed at family scale.
