# watch-bridge

Seats an Apple Watch in a LiveKit call. watchOS has no WebRTC, so the watch
can't join a room itself. This process joins **as the watch's own account**,
using a room token from the app's normal `/api/freecaller/livekit-token`
endpoint, and relays Opus packets between the room and a WebSocket from the
watch. It never decodes audio, so a call costs a memcpy, not a transcode. The
full design is in [`docs/watch-plan.md`](../../docs/watch-plan.md), and the wire
format is in [`protocol.go`](protocol.go).

```
other phone ⇄ LiveKit ⇄ watch-bridge ⇄ wss://pb.holographica.space/bridge/ws ⇄ watch
```

The bridge holds **no credentials**. Every PocketBase call it makes forwards the
watch's own token, so the existing collection rules and the token endpoint
decide who may join which call.

## Develop (any OS with Go)

```bash
cd deploy/watch-bridge
go test ./...          # whole session lifecycle against a fake PocketBase + room
go run .               # needs a PocketBase at PB_URL (default 127.0.0.1:8090)
```

## One-time server setup

1. **Caddy route.** In `/etc/caddy/Caddyfile`, change the `pb.holographica.space`
   block so `/bridge/*` goes to the bridge and everything else still goes to
   PocketBase:

   ```
   pb.holographica.space {
       handle /bridge/* {
           reverse_proxy 127.0.0.1:8095
       }
       handle {
           reverse_proxy 127.0.0.1:8090 {
               flush_interval -1
           }
       }
   }
   ```

   Then run `caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy`.
   Caddy handles the WebSocket upgrade by itself.

2. **Push topic.** Add `"watchBundleId": "com.unnanego.freecaller.watchkitapp"`
   to the `apns` block of `/etc/freecaller/push.json` (see
   `deploy/pocketbase/push/push.json.example`). It uses the same `.p8` key.

3. **PocketBase.** `bash deploy/pocketbase/deploy.sh` ships the `watchos` device
   platform, the `answeredOn` field and the answered-elsewhere push.

## Deploy

```bash
bash deploy/watch-bridge/deploy.sh
```

This runs the tests, cross-compiles a static Linux binary, installs it to
`/opt/watch-bridge/`, installs the systemd unit, restarts the service and checks
`/bridge/healthz` both on loopback and through Caddy.

## Test without a watch

`tools/fakewatch.mjs` speaks the protocol exactly as the watch app does, and
loops the phone's audio back to it:

```bash
PB_URL=https://pb.holographica.space node tools/fakewatch.mjs <watch-user> <phone-user>
```

Answer on the phone and talk. Hearing yourself one round trip later proves the
whole server half: the call record, push, bridge, LiveKit seat and Opus relay in
both directions.

## Endpoints

| Path | What |
|---|---|
| `GET /bridge/ws` | The call socket (`protocol.go`) |
| `GET /bridge/healthz` | `{"ok":true,"sessions":N}` |
| `GET /bridge/echo` | Loops audio straight back, for latency tests on the watch. Only with `BRIDGE_ECHO=1`, and it still needs a valid account token. |
