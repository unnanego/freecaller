#!/usr/bin/env bash
# Point PocketBase at the REG.RU mailbox that sends sign-in codes, and install
# the Russian OTP email template.
#
# Sign-in is a one-time code sent by email and nothing else, so a broken mail
# transport is a total outage: nobody can get into the app at all. PocketBase's
# default mailer shells out to `sendmail`, which does not exist on this box —
# without the settings below, every request-otp silently sends nothing (the API
# still answers 200 with an otpId, because it refuses to leak whether an account
# exists).
#
# BEFORE running: create the mailbox in the REG.RU panel
# (Почта → Почтовые ящики) for the domain whose MX already points at
# mx1.hosting.reg.ru. A dedicated no-reply box is the right shape:
#
#     noreply@holographica.space
#
# The domain's SPF already includes _spf.hosting.reg.ru, so mail sent through
# REG.RU's own SMTP passes SPF — sending from anywhere else would land the codes
# in spam, which for this app is indistinguishable from being locked out.
#
# Run it ON the server (PocketBase is loopback-only), or through a tunnel:
#
#     bash configure-mail.sh
#     SMTP_USER=noreply@holographica.space bash configure-mail.sh   # skip a prompt
#
set -uo pipefail

PB="${PB_URL:-http://127.0.0.1:8090}"
SU_EMAIL="${PB_SUPERUSER_EMAIL:-unnanego@gmail.com}"

SMTP_HOST="${SMTP_HOST:-mail.hosting.reg.ru}"
SMTP_PORT="${SMTP_PORT:-465}"          # 465 = implicit TLS; 587 would be STARTTLS (tls:false)
SMTP_USER="${SMTP_USER:-}"
SENDER_NAME="${SENDER_NAME:-Звонилка}"

# Passwords may also be passed in the environment, for an unattended run.
SU_PW="${PB_SUPERUSER_PASSWORD:-}"
SMTP_PW="${SMTP_PASSWORD:-}"

# Without a TTY the prompts below never reach you and the script just sits there
# looking dead — which is exactly what `ssh host 'bash configure-mail.sh'` does.
if [ ! -t 0 ] && { [ -z "$SU_PW" ] || [ -z "$SMTP_PW" ] || [ -z "$SMTP_USER" ]; }; then
  echo "No terminal to prompt on. Either run it with a TTY:" >&2
  echo "  ssh -t root@<server> 'cd /var/lib/pocketbase && bash configure-mail.sh'" >&2
  echo "or pass everything in the environment:" >&2
  echo "  PB_SUPERUSER_PASSWORD=… SMTP_USER=… SMTP_PASSWORD=… bash configure-mail.sh" >&2
  exit 1
fi

if [ -z "$SU_PW" ]; then
  read -rs -p "superuser password for $SU_EMAIL: " SU_PW; echo
fi
if [ -z "$SMTP_USER" ]; then
  read -r -p "SMTP mailbox (e.g. noreply@holographica.space): " SMTP_USER
fi
if [ -z "$SMTP_PW" ]; then
  read -rs -p "password for $SMTP_USER: " SMTP_PW; echo
fi
echo

TOKEN=$(curl -s -X POST "$PB/api/collections/_superusers/auth-with-password" \
  -H 'Content-Type: application/json' \
  -d "$(python3 - "$SU_EMAIL" "$SU_PW" <<'PY'
import json, sys
print(json.dumps({"identity": sys.argv[1], "password": sys.argv[2]}))
PY
)" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))")

if [ -z "$TOKEN" ]; then
  echo "superuser auth FAILED — wrong password, or PocketBase is not reachable at $PB"
  exit 1
fi

# ---------- SMTP + sender identity -------------------------------------------
SETTINGS=$(python3 - "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER" "$SMTP_PW" "$SENDER_NAME" <<'PY'
import json, sys
host, port, user, password, sender = sys.argv[1:6]
print(json.dumps({
    "smtp": {
        "enabled": True,
        "host": host,
        "port": int(port),
        "username": user,
        "password": password,
        # PLAIN over an implicit-TLS connection: REG.RU accepts it, and the
        # connection is encrypted before the credentials are sent.
        "authMethod": "PLAIN",
        # true = implicit TLS (port 465). On 587 set this false so PocketBase
        # issues STARTTLS instead.
        "tls": port == "465",
    },
    "meta": {
        "senderName": sender,
        # Must be the mailbox itself: REG.RU rejects a From: it does not own.
        "senderAddress": user,
    },
}))
PY
)

OUT=$(curl -s -w '\n%{http_code}' -X PATCH "$PB/api/settings" \
  -H 'Content-Type: application/json' -H "Authorization: $TOKEN" -d "$SETTINGS")
CODE=$(tail -n1 <<<"$OUT")
if [ "$CODE" = "200" ]; then
  echo "  SMTP configured: $SMTP_USER via $SMTP_HOST:$SMTP_PORT"
else
  echo "  SMTP settings FAILED (HTTP $CODE): $(sed '$d' <<<"$OUT")"
  exit 1
fi

# ---------- Russian OTP email ------------------------------------------------
# The default template is English and talks about "one-time password"; the
# people receiving this are a Russian-speaking family, and one of them is being
# read the code aloud by a helper.
TEMPLATE=$(python3 <<'PY'
import json
body = (
    "<p>Здравствуйте!</p>"
    "<p>Ваш код для входа в «Звонилку»:</p>"
    "<p style=\"font-size:28px;letter-spacing:6px\"><strong>{OTP}</strong></p>"
    "<p>Код действует 15 минут и работает один раз.</p>"
    "<p>Если вы не входили в приложение — просто удалите это письмо.</p>"
)
print(json.dumps({
    "otp": {
        "emailTemplate": {
            "subject": "Код для входа в «Звонилку»",
            "body": body,
        }
    }
}))
PY
)

OUT=$(curl -s -w '\n%{http_code}' -X PATCH "$PB/api/collections/users" \
  -H 'Content-Type: application/json' -H "Authorization: $TOKEN" -d "$TEMPLATE")
CODE=$(tail -n1 <<<"$OUT")
if [ "$CODE" = "200" ]; then
  echo "  OTP email template set (Russian)"
else
  echo "  OTP template FAILED (HTTP $CODE): $(sed '$d' <<<"$OUT")"
  exit 1
fi

# ---------- prove it actually sends ------------------------------------------
# Settings that look right but do not deliver are the whole failure mode here,
# so end on a real send rather than on a 200 from a config write.
TEST_TO="${TEST_EMAIL:-}"
if [ -z "$TEST_TO" ] && [ -t 0 ]; then
  read -r -p "send a test OTP email to (blank to skip): " TEST_TO
fi
if [ -n "$TEST_TO" ]; then
  OUT=$(curl -s -w '\n%{http_code}' -X POST "$PB/api/settings/test/email" \
    -H 'Content-Type: application/json' -H "Authorization: $TOKEN" \
    -d "$(python3 - "$TEST_TO" <<'PY'
import json, sys
print(json.dumps({"email": sys.argv[1], "template": "otp", "collection": "users"}))
PY
)")
  CODE=$(tail -n1 <<<"$OUT")
  if [ "$CODE" = "204" ] || [ "$CODE" = "200" ]; then
    echo "  test email accepted by $SMTP_HOST — check $TEST_TO (and its spam folder)"
  else
    echo "  test email FAILED (HTTP $CODE): $(sed '$d' <<<"$OUT")"
    echo "  PocketBase logs: journalctl -u pocketbase -n 50"
    exit 1
  fi
fi

echo
echo "Done. A real end-to-end check is worth more than any of the above:"
echo "  curl -s -X POST $PB/api/collections/users/request-otp \\"
echo "    -H 'Content-Type: application/json' -d '{\"email\":\"<a real account>\"}'"
echo "then confirm the code arrives. request-otp answers 200 even for addresses"
echo "with no account, so only a received email proves anything."
