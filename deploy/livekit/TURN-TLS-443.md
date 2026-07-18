# TURN/TLS on 443 for restrictive networks (Russia, locked-down Wi-Fi)

## Why

Media/signaling currently reach the foreign SFU as **direct WebRTC** (UDP
50000–60000, TCP 7881 fallback). On restrictive networks (Russian DPI,
corporate/hotel Wi-Fi that only allows 443) that path is throttled or reset:
video dies while audio survives, or the call drops a few seconds in.

A TURN server gives clients a **relayed** candidate; TURN **over TLS on 443**
looks like HTTPS, so it survives DPI/port-blocking. When the direct path fails
the client falls back to the relay automatically — no app change (LiveKit
advertises the `turns:` URIs on join).

## This server hosts THREE sites on 443 — not just LiveKit

`livekit.mulstri.com`, `beresta.mulstri.com` (+`content.`), `mulstri.com`.
Only one thing can bind 443, so an nginx `stream` (`ssl_preread`) server takes
443 and SNI-routes:

```
  :443 nginx stream (ssl_preread, proxy_protocol on)
    ├─ SNI turn.mulstri.com → 127.0.0.1:5350 → (strip PROXY) → 127.0.0.1:5349  livekit TURN/TLS
    └─ default              → 127.0.0.1:8443                                    nginx https vhosts
```

All three sites forward the real client IP (`X-Real-IP`) to their backends, so
we MUST preserve it: `stream` prepends the PROXY protocol header, the internal
`:8443` https listeners parse it (`proxy_protocol` + `real_ip_header`). LiveKit
TURN can't parse PROXY, so a tiny second stream server (`:5350`) strips it and
forwards plain TLS to `:5349`.

## Prerequisite: DNS (done — `turn.mulstri.com` → 46.101.124.97)

## Stage 1 — TURN cert (safe; doesn't touch the serving path)

```bash
certbot certonly --nginx -d turn.mulstri.com --non-interactive --agree-tos --keep-until-expiring

install -d -o livekit -g livekit -m 750 /etc/livekit/turn
cat > /etc/letsencrypt/renewal-hooks/deploy/livekit-turn.sh <<'EOF'
#!/bin/sh
D=/etc/letsencrypt/live/turn.mulstri.com
install -o livekit -g livekit -m 640 "$D/fullchain.pem" /etc/livekit/turn/fullchain.pem
install -o livekit -g livekit -m 640 "$D/privkey.pem"   /etc/livekit/turn/privkey.pem
systemctl restart livekit
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/livekit-turn.sh
/etc/letsencrypt/renewal-hooks/deploy/livekit-turn.sh
```

## Stage 2 — enable TURN in LiveKit (independent of nginx; :5349 only)

In `/etc/livekit/livekit.yaml` replace `turn: { enabled: false }` with:

```yaml
turn:
  enabled: true
  domain: turn.mulstri.com
  tls_port: 5349
  cert_file: /etc/livekit/turn/fullchain.pem
  key_file: /etc/livekit/turn/privkey.pem
```

```bash
systemctl restart livekit
sleep 2
ss -ltn | grep 5349          # expect LISTEN on 5349
journalctl -u livekit -n 20 --no-pager   # expect no cert/turn errors
```
WSS calls still work at this point (nothing on 443 changed yet).

## Stage 3 — nginx (the 443 surgery; do as ONE reload, backups first)

```bash
mkdir -p /root/turn-tls-backup && cp -a /etc/nginx /root/turn-tls-backup/nginx-$(date +%s)
apt-get install -y libnginx-mod-stream    # provides the stream module
```

**a. Move every `listen 443 ssl` on the three sites to the internal port.** In
`sites-available/{livekit,beresta,mulstri}.conf`, change each:

    listen 443 ssl;               →  listen 127.0.0.1:8443 ssl proxy_protocol;
    listen [::]:443 ssl ...;      →  (delete — internal listener is 127.0.0.1 only)

Leave the `listen 80` redirect servers untouched.

**b. In `/etc/nginx/nginx.conf`, inside `http { … }`** (near the top) add real-IP
recovery from the local stream proxy:

```nginx
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
```

**c. Append the stream router at the TOP LEVEL of `/etc/nginx/nginx.conf`**
(after the closing `}` of `http`, a sibling block — NOT inside http):

```nginx
stream {
    map $ssl_preread_server_name $lk_upstream {
        turn.mulstri.com  127.0.0.1:5350;   # → strip PROXY → livekit TURN
        default           127.0.0.1:8443;   # → https vhosts
    }
    server {                                 # public 443
        listen 443 reuseport;
        listen [::]:443 reuseport;
        ssl_preread on;
        proxy_protocol on;                   # preserve client IP to :8443
        proxy_pass $lk_upstream;
        proxy_timeout 1h;
    }
    server {                                 # strip PROXY header for TURN
        listen 127.0.0.1:5350 proxy_protocol;
        proxy_pass 127.0.0.1:5349;
        proxy_timeout 1h;
    }
}
```

**d. Test and reload (only reload if the test passes):**

```bash
nginx -t && systemctl reload nginx
```

## Stage 4 — verify

```bash
# all three https sites still serve (SNI routed through the stream):
curl -sI https://livekit.mulstri.com | head -1     # 200/101-ish
curl -sI https://beresta.mulstri.com | head -1
curl -sI https://mulstri.com         | head -1
# TURN reachable over 443 with the right cert:
openssl s_client -connect turn.mulstri.com:443 -servername turn.mulstri.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject                    # subject=CN=turn.mulstri.com
# real client IP preserved (check a backend's logs show real IPs, not 127.0.0.1)
```
Then place a real call; on a Russian network video should now hold. In the
LiveKit log a relayed call shows a `relay` ICE candidate.

## Rollback

```bash
cp -a /root/turn-tls-backup/nginx-*/. /etc/nginx/    # restore configs
nginx -t && systemctl reload nginx
# (LiveKit TURN can stay enabled; it's harmless without the 443 route.)
```

## Notes
- 443 already open in the firewall; no new ports needed (5349/5350 are localhost).
- No plain-UDP TURN (3478): buys nothing over 443/TLS on restrictive nets.
- App needs no change — LiveKit hands clients the `turns:turn.mulstri.com:443` URI.
