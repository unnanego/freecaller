#!/usr/bin/env bash
# Push the hooks, migrations and verify.sh from this repo to the server, then
# restart PocketBase and wait for it to come back.
#
#   bash deploy/pocketbase/deploy.sh [--allow-dirty] [user@host]
#
# Run from the repo root. Defaults to the production box.
#
# Before anything is copied, three things are checked LOCALLY — because the
# first thing this script does on the server is irreversible-ish (a restart on
# new code, in front of people who cannot be told to "try again in a minute"):
#
#   1. deploy/pocketbase is clean in git. What runs in production should be a
#      commit somebody can point at; a half-finished edit that happened to be in
#      the working tree is not one. --allow-dirty (or ALLOW_DIRTY=1) overrides,
#      and says so.
#   2. Every hook and migration parses (`node --check`, when node is installed).
#      A syntax error in ONE hook file makes PocketBase refuse to load it, and
#      the symptom is not an error — it is calls that silently stop ringing.
#   3. The python helpers compile. Same story: push.py failing to import is
#      "nobody's phone rings", discovered by someone not being rung.
#
# Migrations apply on start, so a restart is not optional — and it is also the
# only thing that reloads pb_hooks. Restarting drops every open realtime (SSE)
# connection: clients reconnect on their own, and the app's watches re-read
# state on reconnect, but a call that is ringing at that exact moment can miss
# the state change it was waiting for. Deploy when nobody is on a call.
set -euo pipefail

ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
HOST=""
for arg in "$@"; do
  case "$arg" in
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) HOST="$arg" ;;
  esac
done
HOST="${HOST:-root@176.112.216.205}"
REMOTE_DIR="/var/lib/pocketbase"
HELPER_DIR="/opt/freecaller"
HEALTH_URL="${PB_HEALTH_URL:-https://pb.holographica.space/api/health}"

cd "$(dirname "$0")"

# ---------- preflight (local, changes nothing) --------------------------------
echo "==> preflight"

# `-- .` scopes the check to this directory: unrelated work in lib/ is none of
# this script's business. Untracked files count — a new hook that was never
# committed is exactly the case this exists for.
DIRTY="$(git status --porcelain -- . 2>/dev/null || true)"
if [ -n "$DIRTY" ]; then
  if [ "$ALLOW_DIRTY" = "1" ]; then
    echo "    WARNING: deploying uncommitted changes (--allow-dirty):"
    sed 's/^/      /' <<<"$DIRTY"
  else
    echo "    REFUSING: deploy/pocketbase has uncommitted changes:" >&2
    sed 's/^/      /' <<<"$DIRTY" >&2
    echo "    Commit them, or re-run with --allow-dirty if you mean it." >&2
    exit 1
  fi
fi

if command -v node >/dev/null 2>&1; then
  # goja-only globals (migrate, $app, routerAdd…) are fine: --check parses, it
  # does not run.
  for f in pb_hooks/*.pb.js pb_migrations/*.js; do
    node --check "$f" || { echo "    SYNTAX ERROR in $f — nothing was deployed" >&2; exit 1; }
  done
  echo "    hooks and migrations parse"
else
  echo "    node not found — SKIPPING the hook syntax check"
fi

# Compiled into a throwaway directory so the repo does not grow __pycache__.
PYC_DIR="$(mktemp -d)"
trap 'rm -rf "$PYC_DIR"' EXIT
for f in push/push.py livekit/livekit_token.py; do
  python3 - "$f" "$PYC_DIR/$(basename "$f").pyc" <<'PYCHECK' || { echo "    PYTHON ERROR in $f — nothing was deployed" >&2; exit 1; }
import py_compile, sys
py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)
PYCHECK
done
echo "    python helpers compile"

for f in verify.sh configure-mail.sh configure-ratelimits.sh; do
  bash -n "$f" || { echo "    SHELL SYNTAX ERROR in $f — nothing was deployed" >&2; exit 1; }
done

# ---------- copy --------------------------------------------------------------
echo "==> copying hooks and migrations to $HOST:$REMOTE_DIR"

# pb_hooks is MIRRORED, not just copied over: PocketBase loads every *.pb.js it
# finds, so a hook deleted (or renamed) here kept running on the server forever
# — the old file next to the new one, both registered, the old one winning or
# double-firing depending on the hook. Only *.pb.js is in scope; anything else
# in that directory on the server is left alone.
#
# No -a: as root on the far side it would carry this laptop's numeric uid onto
# the files. Plain -rt gives what scp gave — owned by the ssh user, mode from
# the source file through the remote umask (0644). (No --chmod either: macOS
# ships openrsync, which rejects the F644 form.)
#
# NOT mirrored, deliberately: pb_migrations (PocketBase's _migrations table
# remembers every file it applied, and a migration that vanishes from disk
# cannot be rolled back) and the config/helper directories (they hold files
# that exist only on the server).
if command -v rsync >/dev/null 2>&1 && ssh "$HOST" 'command -v rsync >/dev/null 2>&1'; then
  rsync -rt --delete \
    --include='*.pb.js' --exclude='*' \
    pb_hooks/ "$HOST:$REMOTE_DIR/pb_hooks/"
else
  echo "    rsync missing on one side — scp, then removing stale hooks by name"
  scp pb_hooks/*.pb.js "$HOST:$REMOTE_DIR/pb_hooks/"
  KEEP=" $(cd pb_hooks && ls *.pb.js | tr '\n' ' ')"
  # shellcheck disable=SC2029  # $KEEP and $REMOTE_DIR are meant to expand here
  ssh "$HOST" "cd '$REMOTE_DIR/pb_hooks' && for f in *.pb.js; do [ -e \"\$f\" ] || continue; case '$KEEP' in *\" \$f \"*) ;; *) echo \"    removing stale hook \$f\"; rm -f -- \"\$f\" ;; esac; done"
fi
scp pb_migrations/*.js "$HOST:$REMOTE_DIR/pb_migrations/"
scp verify.sh configure-mail.sh configure-ratelimits.sh "$HOST:$REMOTE_DIR/"

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
echo "Once per server (it is a setting, not code — survives deploys):"
echo "  ssh -t $HOST 'cd $REMOTE_DIR && bash configure-ratelimits.sh'"
