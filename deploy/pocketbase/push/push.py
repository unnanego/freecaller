#!/usr/bin/env python3
"""
Push dispatcher for freecaller — the PocketBase replacement for
functions/src/push.ts.

Invoked by pb_hooks via $os.cmd('python3', '/opt/freecaller/push.py'), with the
job as JSON on **stdin** (not argv, so caller names and tokens stay out of `ps`).

It exists because PocketBase's JS runtime can only sign HS256 JWTs
($security.createJWT), while APNs needs ES256 and FCM v1's OAuth exchange needs
RS256. Delivery happens here too: APNs mandates HTTP/2, which `curl` does and
Python's stdlib does not.

Dependencies: python3 + `cryptography` + `curl` — all already present on the box.

Job on stdin:
  {
    "kind": "ring" | "cancel",
    "call": {"callId": "...", "callerId": "...", "callerName": "...",
             "callerPhone": "...", "video": "true"},
    "devices": [{"id": "...", "platform": "ios",     "voipToken": "..."},
                {"id": "...", "platform": "android", "fcmToken":  "..."}]
  }

Result on stdout:
  {"ok": true, "sent": 2, "failed": 0,
   "results": [{"deviceId": "...", "platform": "ios", "status": 200,
                "unregistered": false, "error": null}, ...]}

`unregistered: true` means the token is dead (APNs 410 / BadDeviceToken, or FCM
UNREGISTERED) and the caller should delete that device record.

Self-test (proves credentials + signing without sending anything):
  python3 push.py --selftest
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, utils

CONFIG_PATH = os.environ.get("FREECALLER_PUSH_CONFIG", "/etc/freecaller/push.json")
CACHE_DIR = os.environ.get("FREECALLER_PUSH_CACHE", "/var/lib/freecaller")

# APNs provider tokens are valid 20–60 min; Google access tokens 1 h. Refresh
# early. Each invocation is a fresh process, so the cache lives on disk.
APNS_JWT_TTL = 45 * 60
FCM_TOKEN_TTL = 50 * 60

HTTP_TIMEOUT = 10
RING_TTL_SECONDS = 45


# ---------------------------------------------------------------- utilities


def b64url(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


def cache_read(name: str, ttl: int):
    path = os.path.join(CACHE_DIR, name)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            blob = json.load(handle)
        if time.time() - blob["mintedAt"] < ttl:
            return blob["token"]
    except (OSError, ValueError, KeyError):
        pass
    return None


def cache_write(name: str, token: str) -> None:
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, name)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump({"token": token, "mintedAt": time.time()}, handle)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# ------------------------------------------------------------------- APNs


def apns_jwt(cfg: dict) -> str:
    """ES256 provider token. Cached, because minting on every push is waste."""
    cached = cache_read("apns_jwt.json", APNS_JWT_TTL)
    if cached:
        return cached

    apns = cfg["apns"]
    with open(apns["keyPath"], "rb") as handle:
        key = serialization.load_pem_private_key(handle.read(), password=None)

    header = b64url(
        json.dumps(
            {"alg": "ES256", "kid": apns["keyId"], "typ": "JWT"},
            separators=(",", ":"),
        ).encode()
    )
    payload = b64url(
        json.dumps(
            {"iss": apns["teamId"], "iat": int(time.time())}, separators=(",", ":")
        ).encode()
    )
    signing_input = header + b"." + payload

    # cryptography returns a DER signature; JWT/APNs require the raw r||s pair.
    # Skip this and Apple rejects every token with no useful diagnostic.
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")

    token = (signing_input + b"." + b64url(raw)).decode()
    cache_write("apns_jwt.json", token)
    return token


APNS_PROD = "https://api.push.apple.com"
APNS_SANDBOX = "https://api.sandbox.push.apple.com"


def apns_hosts(cfg: dict) -> list:
    """Configured environment first, then the other one.

    A token-based .p8 auth key is valid for BOTH environments — what is
    environment-specific is the device token: one minted under a development
    profile resolves only on the sandbox host, and a TestFlight/App Store one
    only on production. Sending to the wrong host fails with 400 BadDeviceToken,
    which looks exactly like a dead token.

    Rather than making `apns.env` a global switch that has to be flipped
    whenever someone installs a locally-built app (and flipped back before an
    upload, or the whole family stops ringing), treat it as a preference and try
    the other host if the first one says the token doesn't belong there. A
    developer's phone and the family's store builds then coexist.
    """
    prod = cfg["apns"].get("env") == "production"
    return [APNS_PROD, APNS_SANDBOX] if prod else [APNS_SANDBOX, APNS_PROD]


def is_wrong_environment(status: int, response: str) -> bool:
    """The one APNs answer that means "right token, wrong host"."""
    return status == 400 and "BadDeviceToken" in response


def send_voip(cfg: dict, device_token: str, body: dict) -> tuple:
    """POST a VoIP push. Returns (status, response_text).

    Tries the second environment only on BadDeviceToken; any other failure is a
    real error and is returned as-is rather than retried against a host that
    cannot help. If BOTH hosts reject the token it stays a BadDeviceToken, so
    the caller still prunes it — a token that is dead in both environments is
    dead.
    """
    result = (0, "")
    for host in apns_hosts(cfg):
        result = post_voip(cfg, host, device_token, body)
        if result[0] == 200 or not is_wrong_environment(*result):
            return result
    return result


def post_voip(cfg: dict, host: str, device_token: str, body: dict) -> tuple:
    """One VoIP push over HTTP/2 via curl, to one APNs host."""
    apns = cfg["apns"]
    args = [
        "curl", "-s", "--http2", "--max-time", str(HTTP_TIMEOUT),
        "-w", "\n%{http_code}",
        "-X", "POST",
        "-H", "apns-topic: {}.voip".format(apns["bundleId"]),
        "-H", "apns-push-type: voip",
        "-H", "apns-priority: 10",
        # 0 = deliver now or discard. Never ring a call that already ended.
        "-H", "apns-expiration: 0",
        "-d", json.dumps(body),
        # The bearer token comes in on stdin so it never appears in `ps`.
        "-K", "-",
        "{}/3/device/{}".format(host, device_token),
    ]
    proc = subprocess.run(
        args,
        input='header = "authorization: bearer {}"\n'.format(apns_jwt(cfg)),
        capture_output=True,
        text=True,
        timeout=HTTP_TIMEOUT + 5,
    )
    out = proc.stdout.rsplit("\n", 1)
    if len(out) != 2:
        return 0, (proc.stderr or proc.stdout).strip()
    return int(out[1] or 0), out[0].strip()


# -------------------------------------------------------------------- FCM


def fcm_access_token(cfg: dict) -> str:
    """RS256-signed service-account assertion exchanged for an OAuth token."""
    cached = cache_read("fcm_token.json", FCM_TOKEN_TTL)
    if cached:
        return cached

    with open(cfg["fcm"]["serviceAccountPath"], "r", encoding="utf-8") as handle:
        account = json.load(handle)

    now = int(time.time())
    header = b64url(
        json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode()
    )
    claims = b64url(
        json.dumps(
            {
                "iss": account["client_email"],
                "scope": "https://www.googleapis.com/auth/firebase.messaging",
                "aud": "https://oauth2.googleapis.com/token",
                "iat": now,
                "exp": now + 3600,
            },
            separators=(",", ":"),
        ).encode()
    )
    signing_input = header + b"." + claims

    key = serialization.load_pem_private_key(
        account["private_key"].encode(), password=None
    )
    signature = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    assertion = (signing_input + b"." + b64url(signature)).decode()

    request = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode(
            {
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            }
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
        token = json.load(response)["access_token"]

    cache_write("fcm_token.json", token)
    return token


def send_fcm(cfg: dict, device_token: str, data: dict) -> tuple:
    """FCM v1 data-only message, high priority so it breaks Doze."""
    with open(cfg["fcm"]["serviceAccountPath"], "r", encoding="utf-8") as handle:
        project_id = json.load(handle)["project_id"]

    message = {
        "message": {
            "token": device_token,
            # Every value must be a string in FCM data payloads.
            "data": {k: str(v) for k, v in data.items()},
            "android": {
                "priority": "high",
                "ttl": "{}s".format(RING_TTL_SECONDS),
            },
        }
    }
    request = urllib.request.Request(
        "https://fcm.googleapis.com/v1/projects/{}/messages:send".format(project_id),
        data=json.dumps(message).encode(),
        headers={
            "Authorization": "Bearer {}".format(fcm_access_token(cfg)),
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()


# ----------------------------------------------------------------- dispatch


def is_unregistered(platform: str, status: int, response: str) -> bool:
    """A dead token — the device record should be deleted by the caller."""
    if platform == "ios":
        return status == 410 or "BadDeviceToken" in response
    return status == 404 or "UNREGISTERED" in response or "NotRegistered" in response


def dispatch(cfg: dict, job: dict) -> dict:
    kind = job.get("kind", "ring")
    call = job.get("call") or {}
    call_id = call.get("callId", "")
    results = []

    for device in job.get("devices") or []:
        platform = device.get("platform")
        entry = {
            "deviceId": device.get("id"),
            "platform": platform,
            "status": 0,
            "unregistered": False,
            "error": None,
        }
        try:
            if platform == "ios":
                token = device.get("voipToken")
                if not token:
                    raise ValueError("ios device has no voipToken")
                # Cancels are VoIP too: the push must still wake the device so
                # PushKit can dismiss the CallKit ring instead of letting it run
                # to the 45s timeout.
                body = (
                    {"callId": call_id, "cancel": "true"}
                    if kind == "cancel"
                    else {
                        "callId": call_id,
                        "callerId": call.get("callerId", ""),
                        "callerName": call.get("callerName", ""),
                        "callerPhone": call.get("callerPhone", ""),
                        "video": call.get("video", "false"),
                    }
                )
                status, response = send_voip(cfg, token, body)

            elif platform == "android":
                token = device.get("fcmToken")
                if not token:
                    raise ValueError("android device has no fcmToken")
                data = (
                    {"type": "cancel_call", "callId": call_id}
                    if kind == "cancel"
                    else {
                        "type": "incoming_call",
                        "callId": call_id,
                        "callerId": call.get("callerId", ""),
                        "callerName": call.get("callerName", ""),
                        "callerPhone": call.get("callerPhone", ""),
                        "video": call.get("video", "false"),
                    }
                )
                status, response = send_fcm(cfg, token, data)

            else:
                raise ValueError("unknown platform: {!r}".format(platform))

            entry["status"] = status
            entry["unregistered"] = is_unregistered(platform, status, response)
            if status < 200 or status >= 300:
                entry["error"] = response[:300]

        except Exception as err:  # noqa: BLE001 - one bad device must not stop the rest
            entry["error"] = "{}: {}".format(type(err).__name__, err)

        results.append(entry)

    sent = sum(1 for r in results if 200 <= r["status"] < 300)
    return {
        "ok": True,
        "kind": kind,
        "callId": call_id,
        "sent": sent,
        "failed": len(results) - sent,
        "results": results,
    }


def selftest(cfg: dict) -> int:
    """Mint both tokens. Proves keys, config and signing without sending."""
    ok = True

    try:
        token = apns_jwt(cfg)
        head = json.loads(base64.urlsafe_b64decode(token.split(".")[0] + "=="))
        print("APNs provider JWT : OK (alg={}, kid={}, {} chars)".format(
            head["alg"], head["kid"], len(token)))
        hosts = apns_hosts(cfg)
        print("APNs endpoints    : {} (falls back to {})".format(hosts[0], hosts[1]))
    except Exception as err:  # noqa: BLE001
        print("APNs provider JWT : FAILED — {}: {}".format(type(err).__name__, err))
        ok = False

    try:
        token = fcm_access_token(cfg)
        with open(cfg["fcm"]["serviceAccountPath"], "r", encoding="utf-8") as handle:
            account = json.load(handle)
        print("FCM access token  : OK ({} chars, project={})".format(
            len(token), account["project_id"]))
    except Exception as err:  # noqa: BLE001
        print("FCM access token  : FAILED — {}: {}".format(type(err).__name__, err))
        ok = False

    print("\n{}".format("SELFTEST PASSED" if ok else "SELFTEST FAILED"))
    return 0 if ok else 1


def main() -> int:
    try:
        cfg = load_config()
    except Exception as err:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": "config {}: {}".format(CONFIG_PATH, err)}))
        return 2

    if "--selftest" in sys.argv:
        return selftest(cfg)

    # The job comes from a file when invoked by pb_hooks, because PocketBase's
    # JS runtime exposes Cmd.stdin as a Go io.Reader that JS can't construct.
    # stdin still works for manual testing.
    try:
        if "--job" in sys.argv:
            with open(sys.argv[sys.argv.index("--job") + 1], "r", encoding="utf-8") as fh:
                job = json.load(fh)
        else:
            job = json.load(sys.stdin)
    except Exception as err:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": "bad job json: {}".format(err)}))
        return 2

    print(json.dumps(dispatch(cfg, job)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
