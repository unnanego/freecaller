# Self-hosted LiveKit for Freecaller (behind nginx)

Runs the open-source LiveKit media server (SFU) on your own VPS, with your
existing nginx terminating TLS for the signaling connection. Handles 1:1
and group calls; the Flutter app and Cloud Functions are identical to the
managed-cloud path — only the URL and keys differ.

## How the pieces connect

- **Signaling (WSS)**: phone → `wss://livekit.YOURDOMAIN.com` → nginx (443,
  your cert) → livekit `127.0.0.1:7880`.
- **Media (audio/video)**: phone ⇄ your server's public IP directly, on
  UDP 50000–60000 (with TCP 7881 as a fallback when UDP is blocked). This
  does not go through nginx.

## Prerequisites

- A VPS with root + Docker + Docker Compose.
- An A record `livekit.YOURDOMAIN.com` → the VPS public IP, covered by an
  SSL cert (wildcard already covers it; otherwise
  `certbot --nginx -d livekit.YOURDOMAIN.com`).
- Firewall open for:
  - **443/tcp** — already open for your site (nginx)
  - **7881/tcp** — WebRTC TCP fallback
  - **50000-60000/udp** — WebRTC media

## Setup

```bash
# on the VPS, in this deploy/livekit directory
cp livekit.yaml.example livekit.yaml

# generate an API key/secret pair; paste into livekit.yaml under `keys:`
docker run --rm livekit/livekit-server generate-keys

docker compose up -d
docker compose logs -f livekit      # "starting LiveKit server"
```

Add the nginx server block and reload:

```bash
cp nginx-livekit.conf.example /etc/nginx/sites-available/livekit.conf
# edit: replace livekit.YOURDOMAIN.com; check the ssl_certificate paths
ln -s /etc/nginx/sites-available/livekit.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

Verify: `curl -i https://livekit.YOURDOMAIN.com` returns a LiveKit response
(HTTP 200/404 from the server, not a cert or 502 error).

## Wire it into the app's backend

Point the Cloud Functions at this server (no app code changes):

```bash
cd ../../functions
firebase functions:secrets:set LIVEKIT_API_KEY      # API key from generate-keys
firebase functions:secrets:set LIVEKIT_API_SECRET   # the secret
echo 'LIVEKIT_URL=wss://livekit.YOURDOMAIN.com' >> .env
firebase deploy --only functions
```

`mintLiveKitToken` now issues tokens for your server, and both apps connect
to it.

## Sizing

Audio + family-scale video is trivial CPU; the smallest VPS (1 vCPU / 1 GB)
is plenty. Video is ~0.3 GB/hour per participant of egress — watch the VPS
bandwidth allowance, not CPU.

## Restrictive networks (only if calls ever fail to connect on some network)

Direct UDP + TCP 7881 covers home wifi and cellular. If a family member is
on a network that blocks everything except TCP 443 (some corporate/hotel
wifi), add TURN/TLS. Because nginx owns 443, the clean way is a second IP
or the nginx `stream` module to SNI-route TURN — open an issue and we'll
wire it then. Not needed for the common case.

## Notes

- `livekit.yaml` holds the API secret and is gitignored — keep it only on
  the server (and the secret in Firebase secrets).
- Upgrade: `docker compose pull && docker compose up -d`.
