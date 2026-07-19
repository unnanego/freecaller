import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";
import { AccessToken } from "livekit-server-sdk";
import { createHmac } from "node:crypto";

const livekitApiKey = defineSecret("LIVEKIT_API_KEY");
const livekitApiSecret = defineSecret("LIVEKIT_API_SECRET");
export const livekitUrl = defineString("LIVEKIT_URL");

// Optional TURN relay (coturn over TLS/443) for clients on networks that
// throttle the direct media path to the SFU. Leave TURN_URL empty to disable;
// when set (e.g. "turns:turn-ru.example.com:443"), the token response carries
// short-lived coturn REST credentials the client feeds to its peer connection.
const turnUrl = defineString("TURN_URL");
const turnSecret = defineSecret("TURN_SHARED_SECRET");

/**
 * coturn `use-auth-secret` (REST) credential: username is an expiry unix
 * timestamp, password is base64(HMAC-SHA1(secret, username)). Credentials are
 * ephemeral (valid ~1h), so they can be handed to the client safely.
 */
function turnCredentials(url: string, secret: string) {
  const username = String(Math.floor(Date.now() / 1000) + 3600);
  const credential = createHmac("sha1", secret).update(username).digest("base64");
  return { urls: [url], username, credential };
}

/**
 * Mints a LiveKit room token for a call participant. Room name == callId,
 * one room per call, never reused. Callable by caller or callee while the
 * call is ringing or accepted.
 */
export const mintLiveKitToken = onCall(
  { secrets: [livekitApiKey, livekitApiSecret, turnSecret] },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required");

    const callId = String(request.data?.callId ?? "").trim();
    if (!callId) throw new HttpsError("invalid-argument", "callId is required");

    const snap = await getFirestore().collection("calls").doc(callId).get();
    if (!snap.exists) throw new HttpsError("not-found", "Unknown call");
    const call = snap.data()!;

    if (call.callerId !== uid && call.calleeId !== uid) {
      throw new HttpsError("permission-denied", "Not a participant of this call");
    }
    if (call.state !== "ringing" && call.state !== "accepted") {
      throw new HttpsError("failed-precondition", `Call is ${call.state}`);
    }

    const at = new AccessToken(livekitApiKey.value(), livekitApiSecret.value(), {
      identity: uid,
      ttl: "1h",
    });
    at.addGrant({
      room: callId,
      roomJoin: true,
      roomCreate: true,
      canPublish: true,
      canSubscribe: true,
    });

    const response: {
      token: string;
      url: string;
      iceServers?: { urls: string[]; username: string; credential: string }[];
    } = { token: await at.toJwt(), url: livekitUrl.value() };

    // Attach the TURN relay only when configured (and its secret is set).
    const turn = turnUrl.value().trim();
    if (turn) {
      response.iceServers = [turnCredentials(turn, turnSecret.value())];
    }
    return response;
  }
);
