# TURN relay on the second IP (coturn, TLS/443) — the fix for cousin's drops

## Why this, and why not embedded TURN

Some clients (e.g. a Russian mobile/Wi-Fi network) throttle or reset the **direct**
WebRTC media path to the SFU (UDP 50000–60000, TCP 7881). It bites the **callee**
specifically: the caller connects to the SFU during the ring window and its
transport settles, but the answerer joins at pickup and can't bring media up in
time → LiveKit fires `RoomDisconnected` → the app hangs up → "call drops right
after answering." A VPN masks it. The durable fix is a **relay over TLS on 443**
(looks like HTTPS, survives DPI); the client falls back to it automatically.

LiveKit's **embedded** TURN can't be used here: it advertises `turns:domain:<tls_port>`
where the advertised port *is* its listen port, and it binds all interfaces — so
it would have to own `:443` host-wide and collide with Caddy's WSS-on-443. Instead
we run **standalone coturn on the second IP** and inject its short-lived
credentials into the client via `mintLiveKitToken` (already wired in code —
`functions/src/livekit.ts` + `lib/services/livekit_service.dart`). Healthy clients
still connect directly; the relay is fallback only (`iceTransportPolicy` stays `all`).

## This box

- **SFU / WSS (leave as-is):** `176.112.216.205` (IP #1) — LiveKit + Caddy.
- **coturn (new):** `176.112.223.58` (IP #2), same VPS → coturn reaches the SFU
  media over the box's own network.
- Provider: flops.ru — its **console firewall** must open ports too, not just ufw
  (same gotcha as MOSCOW-SFU-SETUP.md), or media/cert challenges silently fail.

TURN hostname below is `turn.holographica.space` (a subdomain you control on the
same domain as the WSS host). Rename if you prefer another.

## 1. DNS
`turn.holographica.space` A record → `176.112.223.58`. Verify `dig +short turn.holographica.space` → that IP.
(Leave the SFU/WSS host pointing at `176.112.216.205`.)

## 2. Pin Caddy to IP #1 (so coturn can own IP #2:443)

Caddy binds `0.0.0.0:443` by default, which would grab IP #2 as well. Pin it to
the SFU IP. In `/etc/caddy/Caddyfile`, add a `bind` line to the site block:

```
lk.holographica.space {
    bind 176.112.216.205
    reverse_proxy 127.0.0.1:7880
}
```
```bash
systemctl reload caddy
curl -sI https://lk.holographica.space | head -1     # WSS host still serves (unchanged)
```

## 3. Firewall — open on IP #2 (flops console AND ufw)
`443/tcp` (TURN/TLS), `3478/udp`+`3478/tcp` (plain TURN, cheap bonus),
`49000-49500/udp` (relay range), `80/tcp` (cert issuance/renewal).

```bash
ufw allow 443/tcp; ufw allow 3478; ufw allow 80/tcp; ufw allow 49000:49500/udp
```

## 4. Install coturn + TLS cert
```bash
apt-get update && apt-get install -y coturn certbot
sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn

# Cert for turn.holographica.space, issued on IP #2 so it doesn't touch Caddy on IP #1:
certbot certonly --standalone --http-01-address 176.112.223.58 \
  -d turn.holographica.space --non-interactive --agree-tos -m you@example.com --keep-until-expiring

install -d -o turnserver -g turnserver -m 750 /etc/coturn
cat > /etc/letsencrypt/renewal-hooks/deploy/coturn.sh <<'EOF'
#!/bin/sh
D=/etc/letsencrypt/live/turn.holographica.space
install -o turnserver -g turnserver -m 640 "$D/fullchain.pem" /etc/coturn/fullchain.pem
install -o turnserver -g turnserver -m 640 "$D/privkey.pem"   /etc/coturn/privkey.pem
systemctl restart coturn
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/coturn.sh
/etc/letsencrypt/renewal-hooks/deploy/coturn.sh
```

## 5. coturn config — `/etc/turnserver.conf`

Generate one shared secret and keep it (the Cloud Function needs the SAME value):
`openssl rand -hex 32`.

```conf
# Bind ONLY the second IP — leaves IP #1:443 to Caddy.
listening-ip=176.112.223.58
relay-ip=176.112.223.58
listening-port=3478
tls-listening-port=443
min-port=49000
max-port=49500

# Ephemeral REST credentials (username = expiry timestamp, password = HMAC).
# The Cloud Function mints these; coturn validates against the same secret.
use-auth-secret
static-auth-secret=REPLACE_WITH_SHARED_SECRET
realm=turn.holographica.space
server-name=turn.holographica.space

cert=/etc/coturn/fullchain.pem
pkey=/etc/coturn/privkey.pem

# Drop privileges after binding 443.
proc-user=turnserver
proc-group=turnserver

fingerprint
no-cli
no-multicast-peers
# Hardening: only relay to our SFU, so this can't be abused as an open relay.
# Remove if calls fail to establish (then the SFU is advertising another IP).
denied-peer-ip=0.0.0.0-255.255.255.255
allowed-peer-ip=176.112.216.205
```
```bash
systemctl restart coturn
ss -ltnp | grep -E ':443|:3478'         # coturn LISTEN on 176.112.223.58:443
journalctl -u coturn -n 30 --no-pager   # no cert/bind errors
```

## 6. Wire the backend (no app release beyond the next build)

The token function already returns `iceServers` when `TURN_URL` is set:
```bash
cd functions
# same value as static-auth-secret above:
firebase functions:secrets:set TURN_SHARED_SECRET
# turns: URL the client dials (TLS on 443):
#   set TURN_URL=turns:turn.holographica.space:443 in the deploy env / .env
firebase deploy --only functions:mintLiveKitToken
```
Leaving `TURN_URL` empty disables TURN and the response omits `iceServers` (the
client connects direct, as today) — so this is safe to deploy before coturn is up.

## 7. Verify
```bash
# TURN reachable over 443 with the right cert:
openssl s_client -connect turn.holographica.space:443 -servername turn.holographica.space </dev/null 2>/dev/null \
  | openssl x509 -noout -subject                 # subject=CN=turn.holographica.space
```
- Rebuild the app with the client change and put it on **cousin's** device.
- Place mom→cousin with cousin's **VPN off**. It should now hold.
- `journalctl -u coturn -f` shows an allocation during the call; on the LiveKit
  box a relayed leg shows a `relay` ICE candidate for that participant.

## Rollback
Set `TURN_URL` empty and redeploy `mintLiveKitToken` (clients go direct again);
`systemctl stop coturn`. Caddy's `bind` line is harmless to leave.

## Notes
- Credentials are short-lived (~1h, minted per call) and only handed to
  authenticated users — safe to expose to the client.
- No plain-UDP-only TURN as the primary path: restrictive nets need 443/TLS.
- `iceTransportPolicy` stays `all`, so this never routes healthy calls through the
  relay — it's pure fallback, no quality regression for everyone else.
