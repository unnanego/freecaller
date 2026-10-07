#!/usr/bin/env bash
# Build watch-bridge for the server, copy it there, restart it, check health.
#
#   bash deploy/watch-bridge/deploy.sh [user@host]
#
# Needs Go locally (any OS — the binary is cross-compiled, static, no cgo).
# The one-time server setup (Caddy route, push.json) is in README.md here.
#
# Restarting drops any call a watch is on at that moment. Deploy when nobody
# is on one.
set -euo pipefail

HOST="${1:-root@176.112.216.205}"
cd "$(dirname "$0")"

echo "==> tests"
go vet ./...
go test -count=1 ./...

ARCH="$(ssh "$HOST" uname -m)"
case "$ARCH" in
  x86_64) GOARCH=amd64 ;;
  aarch64) GOARCH=arm64 ;;
  *) echo "unsupported server arch: $ARCH" >&2; exit 1 ;;
esac

echo "==> building linux/$GOARCH"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -trimpath -ldflags "-s -w" -o "$OUT/watch-bridge" .
ls -lh "$OUT/watch-bridge" | awk '{print "    " $5}'

echo "==> installing on $HOST"
ssh "$HOST" 'mkdir -p /opt/watch-bridge'
scp "$OUT/watch-bridge" "$HOST:/opt/watch-bridge/watch-bridge.new"
scp watch-bridge.service "$HOST:/etc/systemd/system/watch-bridge.service"
ssh "$HOST" 'chmod 755 /opt/watch-bridge/watch-bridge.new &&
  mv /opt/watch-bridge/watch-bridge.new /opt/watch-bridge/watch-bridge &&
  systemctl daemon-reload &&
  systemctl enable --quiet watch-bridge &&
  systemctl restart watch-bridge'

echo "==> health"
for i in $(seq 1 10); do
  if ssh "$HOST" 'curl -sf -m 3 http://127.0.0.1:8095/bridge/healthz'; then
    echo
    break
  fi
  sleep 1
  if [ "$i" = "10" ]; then
    echo "    NOT HEALTHY — journalctl -u watch-bridge -n 50" >&2
    exit 1
  fi
done
if curl -sf -m 5 https://pb.holographica.space/bridge/healthz >/dev/null; then
  echo "    reachable from outside through Caddy"
else
  echo "    up on loopback, but NOT through Caddy — is the /bridge/* route in the Caddyfile? (README.md)"
fi
ssh "$HOST" 'journalctl -u watch-bridge -n 5 --no-pager; systemctl show watch-bridge -p MemoryCurrent'
