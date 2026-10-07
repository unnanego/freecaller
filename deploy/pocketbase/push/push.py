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
                {"id": "...", "platform": "watchos", "voipToken": "..."},
                {"id": "...", "platform": "android", "fcmToken":  "..."}]

`watchos` is the Apple Watch app (docs/watch-plan.md): the same VoIP push as
`ios`, sent under the watch app's own topic — apns.watchBundleId in push.json.
  }

Result on stdout:
  {"ok": true, "sent": 2, "failed": 0,
   "results": [{"deviceId": "...", "platform": "ios", "status": 200,
                "unregistered": false, "error": null}, ...]}

`unregistered: true` means the token is dead (APNs 410 / Unregistered /
BadDeviceToken from BOTH hosts, or FCM UNREGISTERED) and the caller should
delete that device record.

Timing: the hook runs this INSIDE the HTTP request that created the call, so
the person dialling waits for it. Devices are therefore sent to concurrently,
under one overall deadline (TOTAL_DEADLINE); a device that has not answered by
then is reported as failed — never as unregistered — and the process exits
anyway. A hard self-kill (HARD_KILL) backs that up.

Self-test (proves credentials + signing without sending anything):
  python3 push.py --selftest
"""

import base64
import concurrent.futures
import json
import os
import re
import signal
import subprocess
import sys
import threading
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

# One transfer (one curl to one APNs host, one FCM POST, one OAuth exchange).
# Short on purpose: a push that has not been accepted in a few seconds is not
# going to ring a phone in time to matter, and the caller is waiting on us.
HTTP_TIMEOUT = 4
CONNECT_TIMEOUT = 3
# Everything, for all devices together. An iOS device may need two transfers
# (wrong-environment fallback), which is why this is twice HTTP_TIMEOUT.
TOTAL_DEADLINE = 8.0
# Past this the process kills itself no matter what is still in flight, so the
# request that spawned us can never hang on a wedged socket or subprocess.
HARD_KILL = 12
# Below this much time left, do not start another transfer.
MIN_TRANSFER = 0.5
MAX_WORKERS = 16
RING_TTL_SECONDS = 45

# An APNs device token is hex. The field it comes from is client-writable, and
# the value goes into a curl URL — so anything else ('/', '?', '{a,b}' globs,
# '..') is refused before curl ever sees it. 64 chars today; Apple reserves the
# right to grow it, hence the open upper end (bounded by the field's own max).
VOIP_TOKEN_RE = re.compile(r"[0-9a-fA-F]{64,200}")


class DeadlineExceeded(Exception):
    """No time left to start (or finish) a transfer."""


def remaining(deadline: float) -> float:
    return deadline - time.monotonic()


def transfer_timeout(deadline: float) -> float:
    left = remaining(deadline)
    if left < MIN_TRANSFER:
        raise DeadlineExceeded("push deadline reached")
    return min(HTTP_TIMEOUT, left)


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
    """Best effort, and never the reason a push fails.

    The cache only saves a signature; the token in hand is valid whether or not
    it could be stored. It used to be written through a fixed `<name>.tmp`, so
    two calls minting at the same moment fought over one temp file, and an
    unwritable directory raised straight through apns_jwt() into "push failed"
    for a phone that was perfectly reachable. The temp file was also created
    with the default mode and only chmod-ed afterwards — a bearer token briefly
    world-readable. So: a temp name of our own (pid + thread), created 0600 and
    exclusively from the first byte, renamed into place, and every error
    swallowed.
    """
    tmp = None
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        path = os.path.join(CACHE_DIR, name)
        tmp = "{}.{}.{}.tmp".format(path, os.getpid(), threading.get_ident())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump({"token": token, "mintedAt": time.time()}, handle)
        os.replace(tmp, path)
        tmp = None
    except Exception:  # noqa: BLE001 - see docstring
        pass
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def cache_drop(name: str) -> None:
    try:
        os.unlink(os.path.join(CACHE_DIR, name))
    except OSError:
        pass


class TokenBox:
    """One provider credential, shared by every sending thread.

    Minted (or read from the disk cache) at most once per process, under a lock,
    so ten devices do not mean ten signatures — and, for APNs, do not mean ten
    provider-token updates, which Apple rate-limits (TooManyProviderTokenUpdates).

    refresh(stale) is what a 401/403 calls: it drops the disk cache and mints
    again, but only if the credential in hand is still the one that was
    rejected. Several devices failing on the same expired token therefore cost
    one re-mint between them, not one each.
    """

    def __init__(self, cache_name: str, ttl: int, mint):
        self._cache_name = cache_name
        self._ttl = ttl
        self._mint = mint
        self._lock = threading.Lock()
        self._token = None

    def get(self) -> str:
        with self._lock:
            if self._token is None:
                self._token = cache_read(self._cache_name, self._ttl)
            if self._token is None:
                self._token = self._mint()
                cache_write(self._cache_name, self._token)
            return self._token

    def refresh(self, stale: str) -> str:
        with self._lock:
            if self._token is None or self._token == stale:
                cache_drop(self._cache_name)
                self._token = self._mint()
                cache_write(self._cache_name, self._token)
            return self._token


_BOXES = {}
_BOXES_LOCK = threading.Lock()


def token_box(key: str, cache_name: str, ttl: int, mint) -> TokenBox:
    with _BOXES_LOCK:
        if key not in _BOXES:
            _BOXES[key] = TokenBox(cache_name, ttl, mint)
        return _BOXES[key]


# ------------------------------------------------------------------- APNs


def apns_box(cfg: dict) -> TokenBox:
    return token_box("apns", "apns_jwt.json", APNS_JWT_TTL, lambda: mint_apns_jwt(cfg))


def apns_jwt(cfg: dict) -> str:
    """ES256 provider token. Cached, because minting on every push is waste."""
    return apns_box(cfg).get()


def mint_apns_jwt(cfg: dict) -> str:
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

    return (signing_input + b"." + b64url(raw)).decode()


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


def is_rejected_provider_token(status: int, response: str) -> bool:
    """APNs saying the JWT — not the device — is the problem."""
    return status == 403 and (
        "ExpiredProviderToken" in response or "InvalidProviderToken" in response
    )


def send_voip(
    cfg: dict, device_token: str, body: dict, deadline: float, bundle_id: str
) -> tuple:
    """POST a VoIP push. Returns (status, response_text).

    Tries the second environment only on BadDeviceToken; any other failure is a
    real error and is returned as-is rather than retried against a host that
    cannot help. If BOTH hosts reject the token it stays a BadDeviceToken, so
    the caller still prunes it — a token that is dead in both environments is
    dead.

    The converse matters just as much now that there is a deadline: ONE host
    saying BadDeviceToken proves nothing (that is simply what the wrong
    environment answers for a healthy token). If time runs out before the
    second host could be asked, the answer is "don't know" — status 0 — and
    never the first host's BadDeviceToken, which the hook would act on by
    deleting a working phone's registration.
    """
    if not VOIP_TOKEN_RE.fullmatch(device_token or ""):
        raise ValueError("voipToken is not a hex APNs device token")

    result = (0, "")
    for host in apns_hosts(cfg):
        try:
            result = post_voip_fresh(cfg, host, device_token, body, deadline, bundle_id)
        except (DeadlineExceeded, subprocess.TimeoutExpired):
            return 0, "push deadline reached before {} answered".format(host)
        if result[0] == 200 or not is_wrong_environment(*result):
            return result
    return result


def post_voip_fresh(cfg, host, device_token, body, deadline, bundle_id) -> tuple:
    """post_voip, plus one retry with a new JWT if APNs rejected the old one.

    The cached JWT is trusted for 45 minutes by our clock. A clock step, a key
    rotated in the Apple portal, or a cache file written by a half-configured
    earlier run all leave a token on disk that APNs refuses with 403 — and
    because every invocation reads the same cache, EVERY push then fails until
    the TTL runs out. So a rejected provider token drops the cache and is
    retried exactly once; a second rejection is a real configuration problem
    and is reported as such.
    """
    box = apns_box(cfg)
    jwt = box.get()
    result = post_voip(cfg, host, device_token, body, jwt, deadline, bundle_id)
    if is_rejected_provider_token(*result):
        result = post_voip(
            cfg, host, device_token, body, box.refresh(jwt), deadline, bundle_id
        )
    return result


def post_voip(cfg, host, device_token, body, jwt, deadline, bundle_id) -> tuple:
    """One VoIP push over HTTP/2 via curl, to one APNs host.

    bundle_id is the app the token belongs to — the iPhone app or the watch app.
    One APNs key signs for every app in the team, so only the topic differs.
    """
    budget = transfer_timeout(deadline)
    args = [
        "curl", "-s", "--http2",
        # No URL globbing: the path segment is validated hex already, and this
        # makes sure curl would not expand {..} / [..] even if it were not.
        "--globoff",
        "--connect-timeout", str(min(CONNECT_TIMEOUT, budget)),
        "--max-time", "{:.1f}".format(budget),
        "-w", "\n%{http_code}",
        "-X", "POST",
        "-H", "apns-topic: {}.voip".format(bundle_id),
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
        input='header = "authorization: bearer {}"\n'.format(jwt),
        capture_output=True,
        text=True,
        # curl enforces --max-time itself; this only catches a curl that
        # ignores it (subprocess.run kills the child on expiry).
        timeout=budget + 1,
    )
    out = proc.stdout.rsplit("\n", 1)
    if len(out) != 2:
        return 0, (proc.stderr or proc.stdout).strip()
    return int(out[1] or 0), out[0].strip()


# -------------------------------------------------------------------- FCM


def fcm_box(cfg: dict) -> TokenBox:
    return token_box(
        "fcm", "fcm_token.json", FCM_TOKEN_TTL, lambda: mint_fcm_access_token(cfg)
    )


def fcm_access_token(cfg: dict) -> str:
    """OAuth access token for FCM v1. Cached on disk between invocations."""
    return fcm_box(cfg).get()


def mint_fcm_access_token(cfg: dict) -> str:
    """RS256-signed service-account assertion exchanged for an OAuth token."""
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
        return json.load(response)["access_token"]


def is_rejected_access_token(status: int, response: str) -> bool:
    """FCM saying the OAuth token — not the device — is the problem.

    401 is always that. 403 usually is too (a revoked or re-scoped token), with
    one exception that is about the DEVICE token and that no new access token
    will fix.
    """
    if status == 401:
        return True
    return status == 403 and "SENDER_ID_MISMATCH" not in response


def send_fcm(cfg: dict, device_token: str, data: dict, deadline: float) -> tuple:
    """send one FCM message; on a rejected access token, re-mint and retry once.

    Same reasoning as post_voip_fresh(): the cached token is trusted for 50
    minutes by our clock, and one that Google has stopped honouring would fail
    every Android push until then.
    """
    box = fcm_box(cfg)
    try:
        access = box.get()
        result = post_fcm(cfg, device_token, data, access, deadline)
        if is_rejected_access_token(*result):
            result = post_fcm(cfg, device_token, data, box.refresh(access), deadline)
        return result
    except DeadlineExceeded as err:
        return 0, str(err)


def post_fcm(cfg, device_token, data, access, deadline) -> tuple:
    """FCM v1 data-only message, high priority so it breaks Doze."""
    budget = transfer_timeout(deadline)
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
            "Authorization": "Bearer {}".format(access),
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=budget) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()


# ----------------------------------------------------------------- dispatch


def is_unregistered(platform: str, status: int, response: str) -> bool:
    """A dead token — the device record should be deleted by the caller.

    Only answers that are ABOUT THE TOKEN and cannot mean anything else:

      iOS      410, or a reason of Unregistered / BadDeviceToken. (send_voip()
               only lets a BadDeviceToken through once both hosts have said it.)
      Android  the literal UNREGISTERED error code in the body. A bare 404 is
               NOT enough: FCM v1 also answers 404 for a wrong project id or a
               mistyped URL, and pruning on that would let one config mistake
               delete every Android phone in the family on the next call.
    """
    if platform in ("ios", "watchos"):
        return (
            status == 410
            or "BadDeviceToken" in response
            or "Unregistered" in response
        )
    return "UNREGISTERED" in response


def send_one(cfg: dict, kind: str, call: dict, device: dict, deadline: float) -> dict:
    """Send to ONE device. Never raises: whatever goes wrong lands in `error`,
    so one bad device cannot stop — or, now, even delay — the rest."""
    call_id = call.get("callId", "")
    platform = device.get("platform")
    entry = {
        "deviceId": device.get("id"),
        "platform": platform,
        "status": 0,
        "unregistered": False,
        "error": None,
    }
    try:
        if platform in ("ios", "watchos"):
            token = device.get("voipToken")
            if not token:
                raise ValueError("{} device has no voipToken".format(platform))
            if platform == "ios":
                bundle_id = cfg["apns"]["bundleId"]
            else:
                bundle_id = cfg["apns"].get("watchBundleId")
                if not bundle_id:
                    raise ValueError("apns.watchBundleId is not configured")
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
            status, response = send_voip(cfg, token, body, deadline, bundle_id)

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
            status, response = send_fcm(cfg, token, data, deadline)

        else:
            raise ValueError("unknown platform: {!r}".format(platform))

        entry["status"] = status
        entry["unregistered"] = is_unregistered(platform, status, response)
        if status < 200 or status >= 300:
            entry["error"] = response[:300]

    except Exception as err:  # noqa: BLE001 - one bad device must not stop the rest
        entry["error"] = "{}: {}".format(type(err).__name__, err)

    return entry


def dispatch(cfg: dict, job: dict) -> dict:
    """Fan the job out to every device at once, under one overall deadline.

    Sequential sending made the caller wait for the SUM of every device's
    latency — and an iOS device can take two transfers — so one unreachable
    phone delayed the ring on all the others and held the "create call" request
    open for the better part of a minute. Threads are enough here: the work is
    all waiting on sockets and on curl.

    Results keep the order of the job's device list, and every device gets an
    entry whatever happened, because the hook's dead-token pruning reads them.
    A device that ran out of time is a plain failure with `unregistered: false`
    — "did not answer" must never be mistaken for "is dead".
    """
    kind = job.get("kind", "ring")
    call = job.get("call") or {}
    call_id = call.get("callId", "")
    devices = [d for d in (job.get("devices") or []) if isinstance(d, dict)]
    deadline = time.monotonic() + TOTAL_DEADLINE

    results = [None] * len(devices)
    if devices:
        pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=min(MAX_WORKERS, len(devices))
        )
        futures = {
            pool.submit(send_one, cfg, kind, call, device, deadline): index
            for index, device in enumerate(devices)
        }
        done, _pending = concurrent.futures.wait(
            futures, timeout=max(0.0, remaining(deadline)) + 0.5
        )
        for future in done:
            results[futures[future]] = future.result()
        # Do not wait for stragglers: main() leaves with os._exit(), and each of
        # them is bounded by its own transfer timeout regardless.
        try:
            pool.shutdown(wait=False, cancel_futures=True)
        except TypeError:  # Python < 3.9 has no cancel_futures
            pool.shutdown(wait=False)

    for index, device in enumerate(devices):
        if results[index] is None:
            results[index] = {
                "deviceId": device.get("id"),
                "platform": device.get("platform"),
                "status": 0,
                "unregistered": False,
                "error": "DeadlineExceeded: no answer within {}s".format(
                    TOTAL_DEADLINE
                ),
            }

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

    # Last line of defence for the request that is blocked on this process: if
    # anything at all is still running at HARD_KILL — a socket that ignores its
    # timeout, a curl that ignores --max-time — say so in the format the hook
    # parses and go. (SIGALRM is delivered to the main thread, which by then is
    # at most waiting on the pool.)
    def give_up(_signum, _frame):
        try:
            sys.stdout.write(json.dumps({
                "ok": False,
                "error": "hard timeout after {}s".format(HARD_KILL),
                "results": [],
            }) + "\n")
            sys.stdout.flush()
        finally:
            os._exit(3)

    try:
        signal.signal(signal.SIGALRM, give_up)
        signal.alarm(HARD_KILL)
    except (AttributeError, ValueError):
        pass  # no SIGALRM on this platform; the deadline still applies

    sys.stdout.write(json.dumps(dispatch(cfg, job)) + "\n")
    sys.stdout.flush()
    # os._exit, not return: a normal interpreter exit joins every worker thread,
    # which would hand the wait we just refused straight back to the caller.
    os._exit(0)


if __name__ == "__main__":
    sys.exit(main())
