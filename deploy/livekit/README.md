# Self-hosted LiveKit for Freecaller (native + nginx)

Runs the open-source LiveKit media server (SFU) natively as a systemd
service on your own VPS, with your existing nginx terminating TLS for the
signaling connection. No Docker (lighter on a small box). Handles 1:1 and
group calls; the Flutter app and Cloud Functions are identical to the
managed-cloud path — only the URL and keys differ.

## How the pieces connect

- **Signaling (WSS)**: phone → `wss://livekit.YOURDOMAIN.com` → nginx (443,
  your cert) → livekit `127.0.0.1:7880`.
- **Media (audio/video)**: phone ⇄ your server's public IP directly, on
  UDP 50000–60000 (with TCP 7881 as a fallback when UDP is blocked). This
  does not go through nginx.

## Prerequisites

- A VPS with root.
- An A record `livekit.YOURDOMAIN.com` → the VPS public IP, covered by an
  SSL cert (wildcard already covers it; otherwise
  `certbot --nginx -d livekit.YOURDOMAIN.com`).
- Reachable (firewall/security group) for:
  - **443/tcp** — already open for your site (nginx)
  - **7881/tcp** — WebRTC TCP fallback
  - **50000-60000/udp** — WebRTC media

## Install the server

```bash
# fetch the latest livekit-server binary (linux amd64) from GitHub releases
# into /usr/local/bin, then a dedicated service user + config dir
useradd --system --no-create-home --shell /usr/sbin/nologin livekit
mkdir -p /etc/livekit
cp livekit.yaml.example /etc/livekit/livekit.yaml

# generate an API key/secret pair; paste into /etc/livekit/livekit.yaml
livekit-server generate-keys

chown -R livekit:livekit /etc/livekit && chmod 600 /etc/livekit/livekit.yaml

# systemd service
cp livekit.service /etc/systemd/system/livekit.service
systemctl daemon-reload
systemctl enable --now livekit
journalctl -u livekit -f      # "starting LiveKit server"
```

## nginx (WSS signaling)

```bash
cp nginx-livekit.conf.example /etc/nginx/sites-available/livekit.conf
# edit: replace livekit.YOURDOMAIN.com
ln -s /etc/nginx/sites-available/livekit.conf /etc/nginx/sites-enabled/
certbot --nginx -d livekit.YOURDOMAIN.com     # issues cert + wires SSL in
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

Audio + family-scale video is trivial CPU; ~256–512 MB RAM is enough for a
handful of participants (add swap on a small box). Video is ~0.3 GB/hour per
participant of egress — watch the VPS bandwidth allowance.

## Restrictive networks (only if calls ever fail to connect on some network)

Direct UDP + TCP 7881 covers home wifi and cellular. If a family member is
on a network that blocks everything except TCP 443, add TURN/TLS. Because
nginx owns 443, the clean way is a second IP or the nginx `stream` module to
SNI-route TURN — open an issue and we'll wire it then. Not needed for the
common case.

## Upgrade

Replace `/usr/local/bin/livekit-server` with the new binary and
`systemctl restart livekit`.
