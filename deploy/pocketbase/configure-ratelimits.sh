#!/usr/bin/env bash
# Turn on PocketBase's built-in rate limiter, with rules for the three places
# where this backend hands something to a caller who has proven nothing yet (or
# very little):
#
#   *:requestOTP        sends a real email from the family's mailbox, to any
#                       account address, for anyone who asks. Unmetered, that is
#                       a mail-bomb aimed at the primary user and a fast way to
#                       get the sending domain blacklisted — which, for an app
#                       whose ONLY sign-in is an emailed code, is a total outage.
#   *:authWithOTP       the code is 8 digits and lives 15 minutes. PocketBase
#                       does not count wrong guesses against an otpId, so the
#                       only thing between an attacker and 10^8 tries is how
#                       fast they are allowed to try.
#   /api/freecaller/    our own routes: discovery (a roster scan per request),
#                       invites, LiveKit tokens (a subprocess per request),
#                       email change.
#
# This is a script and not a migration ON PURPOSE. A settings write that a
# given PocketBase build rejects would, as a migration, fail on startup of the
# production server; here it fails as an HTTP error you are looking at, having
# changed nothing. It is also trivially undone:  bash configure-ratelimits.sh --disable
#
# Requires PocketBase >= 0.23 (the first release with `rateLimits` settings).
# The script checks for the key and SKIPS, changing nothing, if it is absent.
#
# READ THIS BEFORE ENABLING — the limiter counts per client IP. PocketBase sits
# behind Caddy on loopback, so unless it has been told to trust the proxy's
# X-Forwarded-For, EVERY request appears to come from 127.0.0.1 and the whole
# family shares ONE bucket: one person fumbling a sign-in code would lock
# everybody's sign-in. The script refuses to enable limits in that state. Pass
# TRUST_PROXY_HEADER=X-Forwarded-For to have it configure the trusted proxy
# header too (correct for "Caddy on the same box, PocketBase bound to
# 127.0.0.1" — do NOT set it if PocketBase is reachable directly, because then
# clients could forge the header and pick their own bucket).
#
# Existing rules are kept: ours are merged in by label, so PocketBase's own
# defaults (*:auth, *:create, /api/batch, /api/) and anything added from the
# dashboard survive a re-run.
#
# Run it ON the server (PocketBase is loopback-only), or through a tunnel:
#
#     bash configure-ratelimits.sh
#     TRUST_PROXY_HEADER=X-Forwarded-For bash configure-ratelimits.sh
#     bash configure-ratelimits.sh --disable
#
set -uo pipefail

PB="${PB_URL:-http://127.0.0.1:8090}"
SU_EMAIL="${PB_SUPERUSER_EMAIL:-unnanego@gmail.com}"
SU_PW="${PB_SUPERUSER_PASSWORD:-}"
TRUST_PROXY_HEADER="${TRUST_PROXY_HEADER:-}"

MODE="enable"
if [ "${1:-}" = "--disable" ]; then
  MODE="disable"
elif [ -n "${1:-}" ]; then
  echo "usage: bash configure-ratelimits.sh [--disable]" >&2
  exit 2
fi

# Same trap as configure-mail.sh: without a TTY the prompt never renders and the
# script looks hung.
if [ ! -t 0 ] && [ -z "$SU_PW" ]; then
  echo "No terminal to prompt on. Either run it with a TTY:" >&2
  echo "  ssh -t root@<server> 'cd /var/lib/pocketbase && bash configure-ratelimits.sh'" >&2
  echo "or pass the password in the environment (PB_SUPERUSER_PASSWORD=…)." >&2
  exit 1
fi
if [ -z "$SU_PW" ]; then
  read -rs -p "superuser password for $SU_EMAIL: " SU_PW; echo
fi

# (Built through a heredoc rather than an inline -c "{...}": nested quotes inside
# "$(...)" get brace-expanded by older bash, which mangles the JSON.)
CREDS=$(python3 - "$SU_EMAIL" "$SU_PW" <<'PY'
import json, sys
print(json.dumps({"identity": sys.argv[1], "password": sys.argv[2]}))
PY
)
TOKEN=$(curl -s -X POST "$PB/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' -d "$CREDS" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "superuser auth FAILED — wrong password, or PocketBase is not reachable at $PB"
  exit 1
fi

CURRENT=$(curl -s "$PB/api/settings" -H "Authorization: $TOKEN")

# Decide what to send. Prints either a JSON patch on stdout (exit 0), or an
# explanation on stderr with exit 3 (= skip, nothing to do) / 4 (= refuse).
PATCH=$(MODE="$MODE" TRUST_PROXY_HEADER="$TRUST_PROXY_HEADER" python3 -c '
import json, os, sys

try:
    current = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("could not read the current settings\n")
    sys.exit(4)

if "rateLimits" not in current:
    sys.stderr.write(
        "this PocketBase has no rateLimits settings (needs >= 0.23) — skipped, nothing changed\n")
    sys.exit(3)

limits = current.get("rateLimits") or {}
rules = list(limits.get("rules") or [])

if os.environ["MODE"] == "disable":
    print(json.dumps({"rateLimits": {"enabled": False, "rules": rules}}))
    sys.exit(0)

patch = {}

proxy = current.get("trustedProxy") or {}
headers = [h for h in (proxy.get("headers") or []) if h]
want = os.environ.get("TRUST_PROXY_HEADER", "").strip()
if not headers and not want:
    sys.stderr.write(
        "REFUSING: trustedProxy.headers is empty, so behind Caddy every client\n"
        "looks like 127.0.0.1 and the whole family would share one bucket.\n"
        "Re-run with TRUST_PROXY_HEADER=X-Forwarded-For (see the header of this\n"
        "script for when that is and is not safe).\n")
    sys.exit(4)
if not headers and want:
    # Rightmost entry = the address Caddy itself saw. The leftmost one is
    # whatever the client chose to claim.
    patch["trustedProxy"] = {"headers": [want], "useLeftmostIP": False}

# durations are seconds
ours = [
    {"label": "*:requestOTP",     "maxRequests": 5,  "duration": 60},
    {"label": "*:authWithOTP",    "maxRequests": 10, "duration": 60},
    {"label": "/api/freecaller/", "maxRequests": 60, "duration": 60},
]
for rule in ours:
    for existing in rules:
        if existing.get("label") == rule["label"] and not existing.get("audience"):
            existing["maxRequests"] = rule["maxRequests"]
            existing["duration"] = rule["duration"]
            break
    else:
        rules.append(rule)

patch["rateLimits"] = {"enabled": True, "rules": rules}
print(json.dumps(patch))
' <<<"$CURRENT")
STATUS=$?

if [ "$STATUS" = "3" ]; then
  exit 0
elif [ "$STATUS" != "0" ] || [ -z "$PATCH" ]; then
  exit 1
fi

OUT=$(curl -s -w '\n%{http_code}' -X PATCH "$PB/api/settings" \
  -H 'Content-Type: application/json' -H "Authorization: $TOKEN" -d "$PATCH")
CODE=$(tail -n1 <<<"$OUT")
if [ "$CODE" != "200" ]; then
  echo "rate limit settings FAILED (HTTP $CODE) — nothing was changed:"
  sed '$d' <<<"$OUT"
  exit 1
fi

# Show what the server now holds, not what we meant to send.
sed '$d' <<<"$OUT" | python3 -c '
import json, sys
s = json.load(sys.stdin)
limits = s.get("rateLimits") or {}
print("  rate limits: {}".format("ENABLED" if limits.get("enabled") else "disabled"))
for r in limits.get("rules") or []:
    print("    {:<22} {:>4} req / {:>3}s {}".format(
        r.get("label", ""), r.get("maxRequests", 0), r.get("duration", 0),
        r.get("audience", "") or ""))
proxy = s.get("trustedProxy") or {}
print("  trusted proxy headers: {}".format(", ".join(proxy.get("headers") or []) or "(none)"))
'

if [ "$MODE" = "enable" ]; then
  echo
  echo "Check that clients are told apart — from a phone on mobile data, then:"
  echo "  journalctl -u pocketbase -n 20     # or Logs in the dashboard: the"
  echo "  request's userIP must be the phone's public address, not 127.0.0.1."
  echo "Undo at any time:  bash configure-ratelimits.sh --disable"
fi
