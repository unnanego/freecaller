import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { defineSecret, defineString } from "firebase-functions/params";
import { AccessToken } from "livekit-server-sdk";

const livekitApiKey = defineSecret("LIVEKIT_API_KEY");
const livekitApiSecret = defineSecret("LIVEKIT_API_SECRET");
export const livekitUrl = defineString("LIVEKIT_URL");

/**
 * Mints a LiveKit room token for a call participant. Room name == callId,
 * one room per call, never reused. Callable by caller or callee while the
 * call is ringing or accepted.
 */
export const mintLiveKitToken = onCall(
  { secrets: [livekitApiKey, livekitApiSecret] },
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

    return { token: await at.toJwt(), url: livekitUrl.value() };
  }
);
