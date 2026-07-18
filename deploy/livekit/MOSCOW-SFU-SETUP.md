# Move the LiveKit SFU to a Moscow VPS (single-server)

Replaces the DigitalOcean SFU (`46.101.124.97`) with one hosted in Russia so the
throttled Russia→foreign media path disappears. Russia↔Russia = domestic;
Russia↔abroad = Russian side domestic + abroad side inbound-to-Moscow (the
proven-good direction). beresta/mulstri stay on DigitalOcean.

Fill in: `RU_IP` (Moscow public IP), `RU_HOST` (e.g. `lk-ru.mulstri.com`).

## 1. DNS
Point `RU_HOST` A record → `RU_IP`. Verify `dig +short RU_HOST` → `RU_IP`.

## 2. Firewall (provider console AND host)
Open inbound: `80/tcp` (ACME cert issuance), `443/tcp`, `7881/tcp`,
`50000-60000/udp`, `22/tcp`. Russian cloud providers default to a restrictive
network firewall — open these in the console too, not just ufw, or media (and
the cert challenge) silently fails.

## 3. Install LiveKit + Caddy (on the Moscow box)
```bash
curl -sSL https://get.livekit.io | bash          # installs livekit-server
# Caddy (auto TLS — no certbot, no renewal hooks):
apt-get update && apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
```

New API key/secret (do NOT reuse the old ones):
```bash
livekit-server generate-keys        # prints APIxxxx: <secret>; save both
```

`/etc/livekit/livekit.yaml` (mirror of current, new keys):
```yaml
port: 7880
rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
keys:
  <NEW_API_KEY>: <NEW_API_SECRET>
# No TURN needed initially — domestic + inbound-to-Moscow media is direct.
# Add turn/TLS later only if some abroad network turns out to need a 443 relay.
```

systemd unit `/etc/systemd/system/livekit.service` (unprivileged user):
```ini
[Unit]
Description=LiveKit Server
After=network.target
[Service]
User=livekit
ExecStart=/usr/local/bin/livekit-server --config /etc/livekit/livekit.yaml
Restart=on-failure
[Install]
WantedBy=multi-user.target
```
```bash
useradd -r -s /usr/sbin/nologin livekit 2>/dev/null || true
systemctl daemon-reload && systemctl enable --now livekit
ss -ltn | grep -E ':7880|:7881'      # both listening
```

Caddy WSS proxy — the entire `/etc/caddy/Caddyfile` (443 is free on this box;
Caddy fetches/renews the cert automatically and handles the WebSocket upgrade):
```
RU_HOST {
    reverse_proxy 127.0.0.1:7880
}
```
```bash
systemctl restart caddy
sleep 5                                  # give ACME a moment to issue the cert
curl -sI https://RU_HOST | head -1       # 200/101-ish once the cert is issued
journalctl -u caddy -n 20 --no-pager     # confirm "certificate obtained"
```
(Caddy needs 80 + 443 reachable to issue the cert — see the firewall step. If
Let's Encrypt is ever unreachable from the host, a provider-bought cert is the
fallback: `tls /path/cert.pem /path/key.pem` inside the site block.)

## 4. Point the app at the new server (Cloud Functions — no app release)
The app reads the LiveKit URL from `mintLiveKitToken`, so only the function's
config changes:
```bash
# in functions/ project
firebase functions:secrets:set LIVEKIT_API_KEY      # paste NEW key
firebase functions:secrets:set LIVEKIT_API_SECRET   # paste NEW secret
# LIVEKIT_URL is a defineString param — set to wss://RU_HOST:
firebase deploy --only functions:mintLiveKitToken
#   (set LIVEKIT_URL=wss://RU_HOST in the deploy env / .env per your setup)
```
`livekit.ts` already mints against `livekitUrl` + the secrets, so no code change
— just the values.

## 5. Verify, then decommission
- Place mom↔cousin (Israel↔Russia) and a Russia↔Russia call → both hold.
- Watch `journalctl -u livekit` on the Moscow box: participants reach
  `participant active` with `udp host RU_IP` selected candidates, no
  `PEER_CONNECTION_DISCONNECTED`.
- Then on DigitalOcean, revert my TURN/stream changes so beresta/mulstri go back
  to plain 443 (restore from `/root/turn-tls-backup/`), and remove
  `livekit.conf` + the `turn:` block. `nginx -t && systemctl reload nginx`.
```

## Rollback
Repoint `livekit.mulstri.com`/function `LIVEKIT_URL` back to the DO server; it's
untouched until step 5. Zero client impact either way.
