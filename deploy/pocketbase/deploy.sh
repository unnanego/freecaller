#!/usr/bin/env bash
# Push the hooks, migrations and verify.sh from this repo to the server, then
# restart PocketBase and wait for it to come back.
#
#   bash deploy/pocketbase/deploy.sh [user@host]
#
# Run from the repo root. Defaults to the production box.
#
# Migrations apply on start, so a restart is not optional — and it is also the
# only thing that reloads pb_hooks. Restarting drops every open realtime (SSE)
# connection: clients reconnect on their own, and the app's watches re-read
# state on reconnect, but a call that is ringing at that exact moment can miss
# the state change it was waiting for. Deploy when nobody is on a call.
set -euo pipefail

HOST="${1:-root@176.112.216.205}"
REMOTE_DIR="/var/lib/pocketbase"
HELPER_DIR="/opt/freecaller"
HEALTH_URL="${PB_HEALTH_URL:-https://pb.holographica.space/api/health}"

cd "$(dirname "$0")"

echo "==> copying hooks and migrations to $HOST:$REMOTE_DIR"
scp pb_hooks/*.pb.js "$HOST:$REMOTE_DIR/pb_hooks/"
scp pb_migrations/*.js "$HOST:$REMOTE_DIR/pb_migrations/"
scp verify.sh configure-mail.sh "$HOST:$REMOTE_DIR/"

# The senders live outside pb_data because the hooks shell out to them by
# absolute path (and $os.cmd children inherit the systemd sandbox).
echo "==> copying push/livekit helpers to $HOST:$HELPER_DIR"
scp push/push.py livekit/livekit_token.py "$HOST:$HELPER_DIR/"

echo "==> restarting pocketbase"
ssh "$HOST" 'systemctl restart pocketbase'

echo "==> waiting for health"
for i in $(seq 1 20); do
  if curl -sf -m 5 "$HEALTH_URL" >/dev/null; then
    echo "    healthy after ${i}s"
    break
  fi
  sleep 1
  if [ "$i" = "20" ]; then
    echo "    STILL DOWN — journalctl -u pocketbase -n 50"
    exit 1
  fi
done

# A migration that fails leaves the service running on the OLD schema and says
# so only in the log, so surface the startup lines rather than trusting a 200.
echo "==> startup log"
ssh "$HOST" 'journalctl -u pocketbase -n 15 --no-pager'

echo
echo "Next: prove the rules and hooks still hold —"
echo "  ssh $HOST 'cd $REMOTE_DIR && bash verify.sh'"
