#!/usr/bin/env bash
# End-to-end verification of the freecaller PocketBase schema.
#
# Proves the things that collection rules and pb_hooks/*.pb.js only *claim*:
# that a client cannot forge a call, cannot make an illegal state transition,
# cannot resurrect a terminal call, cannot read someone else's call — and that
# deleting an account really does cascade.
#
# Run ON the server. Creates two temporary users and deletes them again.
#
#   bash verify.sh
#
set -uo pipefail

PB="http://127.0.0.1:8090"
SU_EMAIL="${SU_EMAIL:-unnanego@gmail.com}"
FAILED=0

read -rs -p "superuser password for $SU_EMAIL: " SU_PW; echo; echo

# ---------- helpers ----------------------------------------------------------
jqp() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

# req METHOD PATH TOKEN [BODY] -> prints "HTTP_CODE<newline>BODY"
req() {
  local method="$1" path="$2" token="$3" body="${4:-}"
  local args=(-s -w '\n%{http_code}' -X "$method" "$PB$path" -H 'Content-Type: application/json')
  [ -n "$token" ] && args+=(-H "Authorization: $token")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}"
}
code() { tail -n1 <<<"$1"; }
body() { sed '$d' <<<"$1"; }

check() { # expected actual label
  if [ "$1" = "$2" ]; then
    printf '  \033[32mPASS\033[0m  %s (HTTP %s)\n' "$3" "$2"
  else
    printf '  \033[31mFAIL\033[0m  %s — expected HTTP %s, got %s\n' "$3" "$1" "$2"
    FAILED=$((FAILED+1))
  fi
}

# For negative cases: the property under test is "the server refused", not the
# precise status. PocketBase legitimately answers 400 / 403 / 404 depending on
# the operation and on whether it wants to leak the record's existence.
reject() { # actual label
  if [ "$1" -ge 400 ] 2>/dev/null; then
    printf '  \033[32mPASS\033[0m  %s (refused, HTTP %s)\n' "$2" "$1"
  else
    printf '  \033[31mFAIL\033[0m  %s — WAS ALLOWED (HTTP %s)\n' "$2" "$1"
    FAILED=$((FAILED+1))
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------- authenticate as superuser ---------------------------------------
section "0. superuser auth"
R=$(req POST /api/collections/_superusers/auth-with-password "" \
  "$(E="$SU_EMAIL" P="$SU_PW" python3 -c \
     "import json,os;print(json.dumps({'identity':os.environ['E'],'password':os.environ['P']}))")")
SU_TOKEN=$(body "$R" | jqp 'd["token"]')
if [ -z "${SU_TOKEN:-}" ]; then
  echo "  could not authenticate as superuser:"; body "$R" | head -5; exit 1
fi
echo "  authenticated"

# ---------- create two test users -------------------------------------------
section "1. provision test users (superuser only — createRule is null)"
mkuser() { # email displayName -> id
  local r
  r=$(req POST /api/collections/users/records "$SU_TOKEN" \
    "{\"email\":\"$1\",\"displayName\":\"$2\",\"password\":\"verify-temp-pw-123\",\"passwordConfirm\":\"verify-temp-pw-123\",\"verified\":true}")
  if [ "$(code "$r")" != "200" ]; then
    echo "  could not create $1 (HTTP $(code "$r")):"; body "$r" | head -5; return 1
  fi
  body "$r" | jqp 'd["id"]'
}
ALICE=$(mkuser "verify-alice@example.invalid" "Alice") || exit 1
BOB=$(mkuser "verify-bob@example.invalid" "Bob") || exit 1
CAROL=$(mkuser "verify-carol@example.invalid" "Carol") || exit 1
echo "  alice=$ALICE bob=$BOB carol=$CAROL"

# Anonymous self-registration must be impossible.
R=$(req POST /api/collections/users/records "" \
  '{"email":"verify-intruder@example.invalid","displayName":"Intruder","password":"aaaaaaaaaa","passwordConfirm":"aaaaaaaaaa"}')
reject "$(code "$R")" "anonymous cannot self-register (createRule: null)"

# Give bob alice as a contact, so we can prove the relation is stripped later.
req PATCH "/api/collections/users/records/$BOB" "$SU_TOKEN" \
  "{\"contacts\":[\"$ALICE\"]}" >/dev/null

# ---------- impersonate ------------------------------------------------------
section "2. obtain user tokens (impersonation)"
tok() { body "$(req POST "/api/collections/users/impersonate/$1" "$SU_TOKEN" '{"duration":600}')" | jqp 'd["token"]'; }
A_TOK=$(tok "$ALICE"); B_TOK=$(tok "$BOB"); C_TOK=$(tok "$CAROL")
[ -n "$A_TOK" ] && [ -n "$B_TOK" ] && [ -n "$C_TOK" ] || { echo "  impersonation failed"; exit 1; }
echo "  got tokens for alice, bob, carol"

# ---------- call creation ----------------------------------------------------
section "3. call creation rules"
CALL=$(cat /proc/sys/kernel/random/uuid)   # 36-char hyphenated, like Uuid().v4()

R=$(req POST /api/collections/calls/records "$A_TOK" \
  "{\"id\":\"$CALL\",\"callerId\":\"$ALICE\",\"calleeId\":\"$BOB\",\"callerName\":\"Alice\",\"isVideo\":false,\"state\":\"ringing\"}")
check 200 "$(code "$R")" "alice rings bob with a 36-char UUID id"

R=$(req POST /api/collections/calls/records "$A_TOK" \
  "{\"id\":$(printf '"%s"' "$(cat /proc/sys/kernel/random/uuid)"),\"callerId\":\"$BOB\",\"calleeId\":\"$CAROL\",\"state\":\"ringing\"}")
reject "$(code "$R")" "alice CANNOT forge a call as bob (callerId spoof)"

R=$(req POST /api/collections/calls/records "$A_TOK" \
  "{\"id\":$(printf '"%s"' "$(cat /proc/sys/kernel/random/uuid)"),\"callerId\":\"$ALICE\",\"calleeId\":\"$ALICE\",\"state\":\"ringing\"}")
reject "$(code "$R")" "alice CANNOT call herself"

R=$(req POST /api/collections/calls/records "$A_TOK" \
  "{\"id\":$(printf '"%s"' "$(cat /proc/sys/kernel/random/uuid)"),\"callerId\":\"$ALICE\",\"calleeId\":\"$BOB\",\"state\":\"accepted\"}")
reject "$(code "$R")" "a call CANNOT be created already 'accepted'"

# ---------- visibility -------------------------------------------------------
section "4. visibility"
check 200 "$(code "$(req GET "/api/collections/calls/records/$CALL" "$B_TOK")")" "bob (callee) can read the call"
reject "$(code "$(req GET "/api/collections/calls/records/$CALL" "$C_TOK")")" "carol (outsider) CANNOT read the call"
reject "$(code "$(req GET "/api/collections/calls/records/$CALL" "")")" "anonymous CANNOT read the call"

# ---------- state machine ----------------------------------------------------
section "5. state machine (the hook)"
R=$(req PATCH "/api/collections/calls/records/$CALL" "$B_TOK" '{"isVideo":true}')
check 200 "$(code "$R")" "partial PATCH with no 'state' is allowed (setVideo)"

R=$(req PATCH "/api/collections/calls/records/$CALL" "$B_TOK" "{\"callerId\":\"$BOB\"}")
reject "$(code "$R")" "participants are immutable (callerId swap rejected)"

R=$(req PATCH "/api/collections/calls/records/$CALL" "$B_TOK" '{"state":"ended"}')
reject "$(code "$R")" "ringing -> ended is ILLEGAL"

R=$(req PATCH "/api/collections/calls/records/$CALL" "$B_TOK" '{"state":"accepted"}')
check 200 "$(code "$R")" "ringing -> accepted is legal"

R=$(req PATCH "/api/collections/calls/records/$CALL" "$B_TOK" '{"state":"declined"}')
reject "$(code "$R")" "accepted -> declined is ILLEGAL"

R=$(req PATCH "/api/collections/calls/records/$CALL" "$A_TOK" '{"state":"ended","endedBy":"alice"}')
check 200 "$(code "$R")" "accepted -> ended is legal"

R=$(req PATCH "/api/collections/calls/records/$CALL" "$A_TOK" '{"state":"accepted"}')
reject "$(code "$R")" "ended -> accepted is ILLEGAL (terminal state is final)"

R=$(req DELETE "/api/collections/calls/records/$CALL" "$A_TOK")
reject "$(code "$R")" "call history is NOT client-deletable"

# ---------- devices + reports ------------------------------------------------
section "6. devices and reports"
A_INSTALL="verify-install-$(cat /proc/sys/kernel/random/uuid)"
R=$(req POST /api/collections/devices/records "$A_TOK" \
  "{\"user\":\"$ALICE\",\"deviceId\":\"$A_INSTALL\",\"platform\":\"ios\",\"voipToken\":\"verify-token\"}")
check 200 "$(code "$R")" "alice registers her own device"
A_DEV=$(body "$R" | jqp 'd["id"]')

R=$(req POST /api/collections/devices/records "$A_TOK" \
  "{\"user\":\"$BOB\",\"deviceId\":\"verify-install-stolen\",\"platform\":\"ios\",\"voipToken\":\"stolen\"}")
reject "$(code "$R")" "alice CANNOT register a device for bob"

reject "$(code "$(req GET "/api/collections/devices/records/$A_DEV" "$B_TOK")")" "bob CANNOT read alice's push token"

# The same physical phone signing into another account: the old registration
# must go, or it keeps ringing for the account it left (pb_hooks/devices.pb.js).
R=$(req POST /api/collections/devices/records "$B_TOK" \
  "{\"user\":\"$BOB\",\"deviceId\":\"$A_INSTALL\",\"platform\":\"ios\",\"voipToken\":\"bob-took-over\"}")
check 200 "$(code "$R")" "bob re-registers the SAME install"
B_DEV_TAKEOVER=$(body "$R" | jqp 'd["id"]')
check 404 "$(code "$(req GET "/api/collections/devices/records/$A_DEV" "$SU_TOKEN")")" \
  "  -> alice's registration for that install is gone (no phantom ring)"
req DELETE "/api/collections/devices/records/$B_DEV_TAKEOVER" "$B_TOK" >/dev/null
R=$(req POST /api/collections/devices/records "$A_TOK" \
  "{\"user\":\"$ALICE\",\"deviceId\":\"$A_INSTALL\",\"platform\":\"ios\",\"voipToken\":\"verify-token\"}")
A_DEV=$(body "$R" | jqp 'd["id"]')

R=$(req POST /api/collections/reports/records "$A_TOK" \
  "{\"reporterUid\":\"$ALICE\",\"type\":\"child_safety\",\"message\":\"verify.sh test report\"}")
check 200 "$(code "$R")" "alice can file a safety report"
A_REPORT=$(body "$R" | jqp 'd["id"]')

reject "$(code "$(req GET "/api/collections/reports/records/$A_REPORT" "$A_TOK")")" "reports are NOT readable back by clients"

# ---------- push fan-out -----------------------------------------------------
section "7. push fan-out (hook -> push.py -> APNs/FCM)"

# A syntactically valid but nonexistent APNs token: Apple answers
# 400 BadDeviceToken, which is an unambiguous "this token is dead".
R=$(req POST /api/collections/devices/records "$B_TOK" \
  "{\"user\":\"$BOB\",\"deviceId\":\"verify-install-ios-$$\",\"platform\":\"ios\",\"voipToken\":\"$(printf '0%.0s' {1..64})\"}")
check 200 "$(code "$R")" "bob registers an iOS device"
B_DEV_IOS=$(body "$R" | jqp 'd["id"]')

CALL3=$(cat /proc/sys/kernel/random/uuid)
R=$(req POST /api/collections/calls/records "$A_TOK" \
  "{\"id\":\"$CALL3\",\"callerId\":\"$ALICE\",\"calleeId\":\"$BOB\",\"callerName\":\"Alice\",\"isVideo\":false,\"state\":\"ringing\"}")
check 200 "$(code "$R")" "alice rings bob (should trigger the push hook)"

sleep 4
# Match loosely, then inspect: "hook never ran" and "hook ran but the push
# failed" are different diagnoses and a literal grep conflates them.
LOGLINE=$(journalctl -u pocketbase --since "90 seconds ago" --no-pager \
          | grep -E "ring push.*$CALL3" | tail -1)
if [ -z "$LOGLINE" ]; then
  printf '  \033[31mFAIL\033[0m  no "ring push" line for %s — hook did not run\n' "$CALL3"
  FAILED=$((FAILED+1))
elif [[ "$LOGLINE" == *FAILED* ]]; then
  printf '  \033[31mFAIL\033[0m  hook ran but the push errored: %s\n' "${LOGLINE#*FAILED }"
  FAILED=$((FAILED+1))
else
  printf '  \033[32mPASS\033[0m  hook invoked push.py and it returned a result\n'
fi

# APNs said BadDeviceToken, so the hook must have deleted the device record.
# This single check proves the whole chain: hook fired -> helper ran -> reached
# Apple -> result parsed -> acted upon.
check 404 "$(code "$(req GET "/api/collections/devices/records/$B_DEV_IOS" "$SU_TOKEN")")" \
  "  -> dead iOS token pruned (APNs BadDeviceToken)"

# FCM's INVALID_ARGUMENT is ambiguous (it also fires for a malformed payload),
# so an Android token must NOT be pruned on it — otherwise a bug in our message
# construction would silently wipe every device in the database.
R=$(req POST /api/collections/devices/records "$B_TOK" \
  "{\"user\":\"$BOB\",\"deviceId\":\"verify-install-android-$$\",\"platform\":\"android\",\"fcmToken\":\"bogus-token-for-verification\"}")
check 200 "$(code "$R")" "bob registers an Android device"
B_DEV_AND=$(body "$R" | jqp 'd["id"]')

CALL4=$(cat /proc/sys/kernel/random/uuid)
req POST /api/collections/calls/records "$A_TOK" \
  "{\"id\":\"$CALL4\",\"callerId\":\"$ALICE\",\"calleeId\":\"$BOB\",\"callerName\":\"Alice\",\"isVideo\":false,\"state\":\"ringing\"}" >/dev/null
sleep 4
check 200 "$(code "$(req GET "/api/collections/devices/records/$B_DEV_AND" "$SU_TOKEN")")" \
  "  -> Android token NOT pruned on ambiguous FCM error"

# Caller hangs up before pickup -> the callee's ring must be dismissed.
R=$(req PATCH "/api/collections/calls/records/$CALL4" "$A_TOK" '{"state":"cancelled"}')
check 200 "$(code "$R")" "alice cancels the ringing call"
sleep 4
LOGLINE=$(journalctl -u pocketbase --since "90 seconds ago" --no-pager \
          | grep -E "cancel push.*$CALL4" | tail -1)
if [ -z "$LOGLINE" ]; then
  printf '  \033[31mFAIL\033[0m    -> no "cancel push" line for %s\n' "$CALL4"
  FAILED=$((FAILED+1))
elif [[ "$LOGLINE" == *FAILED* ]]; then
  printf '  \033[31mFAIL\033[0m    -> cancel push errored: %s\n' "${LOGLINE#*FAILED }"
  FAILED=$((FAILED+1))
else
  printf '  \033[32mPASS\033[0m    -> cancel push dispatched\n'
fi

# No job files may be left lying around in the spool directory.
LEFTOVER=$(ls /var/lib/freecaller/job-*.json 2>/dev/null | wc -l)
if [ "$LEFTOVER" -eq 0 ]; then
  printf '  \033[32mPASS\033[0m    -> temp job files cleaned up\n'
else
  printf '  \033[31mFAIL\033[0m    -> %s job file(s) left in /var/lib/freecaller\n' "$LEFTOVER"
  FAILED=$((FAILED+1))
fi

# ---------- LiveKit token endpoint -------------------------------------------
section "8. LiveKit room token (/api/freecaller/livekit-token)"

# CALL3 is still ringing from section 7; CALL is ended from section 5.
R=$(req POST /api/freecaller/livekit-token "$A_TOK" "{\"callId\":\"$CALL3\"}")
check 200 "$(code "$R")" "participant gets a token for a ringing call"
LK_BODY=$(body "$R")

CLAIMS=$(printf '%s' "$LK_BODY" | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
t = d.get('token','')
p = t.split('.')[1] if t.count('.') == 2 else ''
c = json.loads(base64.urlsafe_b64decode(p + '==')) if p else {}
print(json.dumps({'iss': c.get('iss'), 'sub': c.get('sub'),
                  'room': (c.get('video') or {}).get('room'),
                  'join': (c.get('video') or {}).get('roomJoin'),
                  'url': d.get('url'),
                  'ice': bool(d.get('iceServers'))}))
" 2>/dev/null)

if [ -n "$CLAIMS" ]; then
  ROOM=$(printf '%s' "$CLAIMS" | jqp 'd["room"]')
  SUB=$(printf '%s' "$CLAIMS" | jqp 'd["sub"]')
  ICE=$(printf '%s' "$CLAIMS" | jqp 'd["ice"]')
  [ "$ROOM" = "$CALL3" ] && printf '  \033[32mPASS\033[0m    -> token room == callId\n' \
    || { printf '  \033[31mFAIL\033[0m    -> token room %s != callId %s\n' "$ROOM" "$CALL3"; FAILED=$((FAILED+1)); }
  [ "$SUB" = "$ALICE" ] && printf '  \033[32mPASS\033[0m    -> token identity == caller uid\n' \
    || { printf '  \033[31mFAIL\033[0m    -> token sub %s != %s\n' "$SUB" "$ALICE"; FAILED=$((FAILED+1)); }
  [ "$ICE" = "True" ] && printf '  \033[32mPASS\033[0m    -> TURN iceServers attached\n' \
    || { printf '  \033[31mFAIL\033[0m    -> no iceServers in the response\n'; FAILED=$((FAILED+1)); }
else
  printf '  \033[31mFAIL\033[0m    -> could not decode the minted token\n'; FAILED=$((FAILED+1))
fi

reject "$(code "$(req POST /api/freecaller/livekit-token "$C_TOK" "{\"callId\":\"$CALL3\"}")")" \
  "outsider CANNOT get a token for someone else's call"
reject "$(code "$(req POST /api/freecaller/livekit-token "" "{\"callId\":\"$CALL3\"}")")" \
  "anonymous CANNOT get a token"
reject "$(code "$(req POST /api/freecaller/livekit-token "$A_TOK" "{\"callId\":\"$(cat /proc/sys/kernel/random/uuid)\"}")")" \
  "no token for an unknown call"
reject "$(code "$(req POST /api/freecaller/livekit-token "$A_TOK" "{\"callId\":\"$CALL\"}")")" \
  "no token for an ENDED call (nobody rejoins a finished room)"
reject "$(code "$(req POST /api/freecaller/livekit-token "$A_TOK" '{}')")" \
  "callId is required"

# ---------- contact discovery + invitations ----------------------------------
section "9. contacts (/api/freecaller/match-contacts, /api/freecaller/invite)"

# Discovery matches on the roster's phone numbers, so give bob one.
BOB_PHONE="+79990000$(printf '%03d' $((RANDOM % 1000)))"
req PATCH "/api/collections/users/records/$BOB" "$SU_TOKEN" \
  "{\"phone\":\"$BOB_PHONE\"}" >/dev/null

reject "$(code "$(req POST /api/freecaller/match-contacts "" "{\"phones\":[\"$BOB_PHONE\"]}")")" \
  "match-contacts requires sign-in"

R=$(req POST /api/freecaller/match-contacts "$A_TOK" "{\"phones\":[\"$BOB_PHONE\",\"+79999999999\"]}")
check 200 "$(code "$R")" "alice matches her address book"
MATCHED=$(body "$R" | jqp 'd["matches"]')
if [[ "$MATCHED" == *"$BOB"* ]]; then
  printf '  \033[32mPASS\033[0m    -> bob'"'"'s number resolved to his uid\n'
else
  printf '  \033[31mFAIL\033[0m    -> bob NOT matched: %s\n' "$MATCHED"
  FAILED=$((FAILED+1))
fi

# Your own number must never come back as a contact of yours.
req PATCH "/api/collections/users/records/$ALICE" "$SU_TOKEN" \
  '{"phone":"+79990001111"}' >/dev/null
MATCHED=$(body "$(req POST /api/freecaller/match-contacts "$A_TOK" '{"phones":["+79990001111"]}')" | jqp 'd["matches"]')
if [[ "$MATCHED" != *"$ALICE"* ]]; then
  printf '  \033[32mPASS\033[0m    -> alice is never matched to herself\n'
else
  printf '  \033[31mFAIL\033[0m    -> alice matched herself: %s\n' "$MATCHED"
  FAILED=$((FAILED+1))
fi

reject "$(code "$(req POST /api/freecaller/invite "$A_TOK" '{"name":"Nobody","phone":"+79990002222"}')")" \
  "invite without an email is rejected"

INVITE_EMAIL="verify-invitee-$$@example.invalid"
R=$(req POST /api/freecaller/invite "$A_TOK" \
  "{\"name\":\"Invitee\",\"phone\":\"+79990002222\",\"email\":\"$INVITE_EMAIL\"}")
check 200 "$(code "$R")" "alice invites someone new"
INVITEE=$(body "$R" | jqp 'd["uid"]')

# The invitation email is best-effort: example.invalid cannot receive one, and
# the invite must still succeed. Proving `emailed` is reported (either way) is
# what matters — a silent failure would leave the inviter thinking the person
# was told when nobody was.
if [ -n "$(body "$R" | jqp 'd.get("emailed")')" ]; then
  printf '  \033[32mPASS\033[0m    -> reports whether the invitation was emailed (%s)\n' \
    "$(body "$R" | jqp 'd["emailed"]')"
else
  printf '  \033[31mFAIL\033[0m    -> response has no "emailed" field\n'
  FAILED=$((FAILED+1))
fi

ALICE_CONTACTS=$(body "$(req GET "/api/collections/users/records/$ALICE" "$SU_TOKEN")" | jqp 'd.get("contacts")')
INVITEE_CONTACTS=$(body "$(req GET "/api/collections/users/records/$INVITEE" "$SU_TOKEN")" | jqp 'd.get("contacts")')
if [[ "$ALICE_CONTACTS" == *"$INVITEE"* && "$INVITEE_CONTACTS" == *"$ALICE"* ]]; then
  printf '  \033[32mPASS\033[0m    -> linked BOTH ways (a one-way roster edge is useless)\n'
else
  printf '  \033[31mFAIL\033[0m    -> not mutually linked: %s / %s\n' "$ALICE_CONTACTS" "$INVITEE_CONTACTS"
  FAILED=$((FAILED+1))
fi

# Inviting the same person again must link, never duplicate the account.
R=$(req POST /api/freecaller/invite "$A_TOK" \
  "{\"name\":\"Invitee\",\"phone\":\"+79990002222\",\"email\":\"$INVITE_EMAIL\"}")
check 200 "$(code "$R")" "inviting the same person twice is idempotent"
if [ "$(body "$R" | jqp 'd["uid"]')" = "$INVITEE" ]; then
  printf '  \033[32mPASS\033[0m    -> reused the existing account\n'
else
  printf '  \033[31mFAIL\033[0m    -> created a SECOND account for the same person\n'
  FAILED=$((FAILED+1))
fi

# ---------- fixed reviewer codes ---------------------------------------------
section "10. pinned review codes (pb_hooks/review_otp.pb.js)"

REVIEW_FILE=/etc/freecaller/review-otp.json
if [ -e "$REVIEW_FILE" ]; then
  echo "  SKIP — $REVIEW_FILE exists; not touching a live review config"
else
  PINNED="13571357"
  printf '{"verify-carol@example.invalid":"%s"}\n' "$PINNED" > "$REVIEW_FILE"
  chmod 640 "$REVIEW_FILE"; chgrp pocketbase "$REVIEW_FILE" 2>/dev/null

  # request-otp mails the (ignored) generated code, so a mail transport that
  # cannot deliver to example.invalid makes this inconclusive rather than
  # failing — the pinning itself is what is under test.
  OTP_ID=$(body "$(req POST /api/collections/users/request-otp "" \
    '{"email":"verify-carol@example.invalid"}')" | jqp 'd["otpId"]')

  if [ -z "$OTP_ID" ]; then
    echo "  SKIP — request-otp returned no otpId (SMTP cannot deliver to example.invalid?)"
  else
    check 200 "$(code "$(req POST /api/collections/users/auth-with-otp "" \
      "{\"otpId\":\"$OTP_ID\",\"password\":\"$PINNED\"}")")" \
      "listed account signs in with the PINNED code"

    # The blast radius is exactly the listed accounts and no one else.
    OTP_ID=$(body "$(req POST /api/collections/users/request-otp "" \
      '{"email":"verify-bob@example.invalid"}')" | jqp 'd["otpId"]')
    if [ -n "$OTP_ID" ]; then
      reject "$(code "$(req POST /api/collections/users/auth-with-otp "" \
        "{\"otpId\":\"$OTP_ID\",\"password\":\"$PINNED\"}")")" \
        "an UNLISTED account is NOT signed in by that code"
    fi
  fi

  rm -f "$REVIEW_FILE"
  echo "  ($REVIEW_FILE removed — the file IS the off switch)"
fi

# ---------- account deletion (App Store 5.1.1(v)) ----------------------------
section "11. account deletion cascade"
CALL2=$(cat /proc/sys/kernel/random/uuid)
req POST /api/collections/calls/records "$A_TOK" \
  "{\"id\":\"$CALL2\",\"callerId\":\"$ALICE\",\"calleeId\":\"$BOB\",\"state\":\"ringing\"}" >/dev/null

reject "$(code "$(req DELETE "/api/collections/users/records/$BOB" "$A_TOK")")" "alice CANNOT delete bob's account"

R=$(req DELETE "/api/collections/users/records/$ALICE" "$A_TOK")
check 204 "$(code "$R")" "alice CAN delete her own account"   # 204 No Content

sleep 1
check 404 "$(code "$(req GET "/api/collections/users/records/$ALICE" "$SU_TOKEN")")" "  -> user record gone"
check 404 "$(code "$(req GET "/api/collections/devices/records/$A_DEV" "$SU_TOKEN")")" "  -> devices cascaded (relation)"
check 404 "$(code "$(req GET "/api/collections/calls/records/$CALL2" "$SU_TOKEN")")" "  -> call history purged (onRecordDelete hook)"
check 200 "$(code "$(req GET "/api/collections/reports/records/$A_REPORT" "$SU_TOKEN")")" "  -> safety report SURVIVES (deliberate)"

BOB_CONTACTS=$(body "$(req GET "/api/collections/users/records/$BOB" "$SU_TOKEN")" | jqp 'd.get("contacts")')
if [[ "$BOB_CONTACTS" != *"$ALICE"* ]]; then
  printf '  \033[32mPASS\033[0m    -> stripped from bob'"'"'s contacts (now: %s)\n' "$BOB_CONTACTS"
else
  printf '  \033[31mFAIL\033[0m    -> still in bob'"'"'s contacts: %s\n' "$BOB_CONTACTS"
  FAILED=$((FAILED+1))
fi

# ---------- cleanup ----------------------------------------------------------
section "12. cleanup"
for u in "$BOB" "$CAROL" "$INVITEE"; do req DELETE "/api/collections/users/records/$u" "$SU_TOKEN" >/dev/null; done
req DELETE "/api/collections/reports/records/$A_REPORT" "$SU_TOKEN" >/dev/null
echo "  test users and report removed"

# ---------- result -----------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
  printf '\n\033[32mALL CHECKS PASSED\033[0m\n'
else
  printf '\n\033[31m%s CHECK(S) FAILED\033[0m\n' "$FAILED"
  exit 1
fi
