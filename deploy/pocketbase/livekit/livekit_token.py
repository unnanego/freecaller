#!/usr/bin/env python3
"""
Mints a LiveKit room token (+ optional coturn REST credential) for one call
participant. The PocketBase replacement for functions/src/livekit.ts.

Authorization is NOT done here — pb_hooks/livekit.pb.js has already checked that
the caller is a participant of a call in a joinable state. This process only does
crypto and config lookup.

Why a subprocess at all, when a LiveKit token is HS256 and $security.createJWT
could sign it: coturn's REST credential needs **HMAC-SHA1**, and PocketBase's JS
runtime exposes no SHA-1 at all (only md5/sha256/sha512/hs256/hs512). Since one
subprocess is unavoidable, both tokens are minted here rather than splitting the
crypto across two languages.

Job (via --job <path>, or stdin):
  {"identity": "<user id>", "room": "<callId>", "ttlSeconds": 3600}

Output:
  {"token": "...", "url": "wss://...",
   "iceServers": [{"urls": ["turns:..."], "username": "...", "credential": "..."}]}

`iceServers` is omitted when no TURN url is configured.

Self-test (mints a token and prints its decoded claims, no secrets):
  python3 livekit_token.py --selftest
"""

import base64
import hashlib
import hmac
import json
import os
import sys
import time

CONFIG_PATH = os.environ.get(
    "FREECALLER_LIVEKIT_CONFIG", "/etc/freecaller/livekit.json"
)

DEFAULT_TTL = 3600


def b64url(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


def livekit_token(cfg: dict, identity: str, room: str, ttl: int) -> str:
    """HS256 JWT in the shape livekit-server expects (grant under `video`)."""
    lk = cfg["livekit"]
    now = int(time.time())

    header = b64url(
        json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    )
    payload = b64url(
        json.dumps(
            {
                "iss": lk["apiKey"],
                "sub": identity,
                "name": identity,
                "nbf": now,
                "exp": now + ttl,
                "video": {
                    # One room per call, named after the callId, never reused.
                    "room": room,
                    "roomJoin": True,
                    "roomCreate": True,
                    "canPublish": True,
                    "canSubscribe": True,
                },
            },
            separators=(",", ":"),
        ).encode()
    )
    signing_input = header + b"." + payload
    signature = hmac.new(
        lk["apiSecret"].encode(), signing_input, hashlib.sha256
    ).digest()
    return (signing_input + b"." + b64url(signature)).decode()


def turn_credentials(cfg: dict, ttl: int):
    """
    coturn `use-auth-secret` (REST) credential: the username is an expiry unix
    timestamp and the password is base64(HMAC-SHA1(secret, username)). Ephemeral,
    so handing it to a client is safe.

    Returns None when TURN is not configured.
    """
    turn = cfg.get("turn") or {}
    url = (turn.get("url") or "").strip()
    secret = turn.get("sharedSecret") or ""
    if not url or not secret:
        return None

    username = str(int(time.time()) + ttl)
    credential = base64.b64encode(
        hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
    ).decode()
    return {"urls": [url], "username": username, "credential": credential}


def build(cfg: dict, job: dict) -> dict:
    identity = str(job.get("identity") or "").strip()
    room = str(job.get("room") or "").strip()
    if not identity or not room:
        raise ValueError("identity and room are required")

    ttl = int(job.get("ttlSeconds") or DEFAULT_TTL)

    response = {
        "token": livekit_token(cfg, identity, room, ttl),
        "url": cfg["livekit"]["url"],
    }
    ice = turn_credentials(cfg, ttl)
    if ice:
        response["iceServers"] = [ice]
    return response


def selftest(cfg: dict) -> int:
    try:
        out = build(cfg, {"identity": "selftest-user", "room": "selftest-room"})
        claims = json.loads(
            base64.urlsafe_b64decode(out["token"].split(".")[1] + "==")
        )
        print("LiveKit token  : OK ({} chars)".format(len(out["token"])))
        print("  iss (apiKey) : {}".format(claims["iss"]))
        print("  sub/room     : {} / {}".format(claims["sub"], claims["video"]["room"]))
        print("  ttl          : {}s".format(claims["exp"] - claims["nbf"]))
        print("LiveKit url    : {}".format(out["url"]))
        if "iceServers" in out:
            print("TURN relay     : OK {}".format(out["iceServers"][0]["urls"][0]))
            print("  username     : {} (expiry timestamp)".format(
                out["iceServers"][0]["username"]))
        else:
            print("TURN relay     : not configured (direct media only)")
        print("\nSELFTEST PASSED")
        return 0
    except Exception as err:  # noqa: BLE001
        print("SELFTEST FAILED — {}: {}".format(type(err).__name__, err))
        return 1


def main() -> int:
    try:
        cfg = load_config()
    except Exception as err:  # noqa: BLE001
        print(json.dumps({"error": "config {}: {}".format(CONFIG_PATH, err)}))
        return 2

    if "--selftest" in sys.argv:
        return selftest(cfg)

    try:
        if "--job" in sys.argv:
            with open(sys.argv[sys.argv.index("--job") + 1], "r", encoding="utf-8") as fh:
                job = json.load(fh)
        else:
            job = json.load(sys.stdin)
    except Exception as err:  # noqa: BLE001
        print(json.dumps({"error": "bad job json: {}".format(err)}))
        return 2

    try:
        print(json.dumps(build(cfg, job)))
    except Exception as err:  # noqa: BLE001
        print(json.dumps({"error": "{}: {}".format(type(err).__name__, err)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
