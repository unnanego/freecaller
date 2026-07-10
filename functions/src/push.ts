import * as http2 from "node:http2";
import { createPrivateKey } from "node:crypto";
import { getMessaging } from "firebase-admin/messaging";
import { defineSecret, defineString } from "firebase-functions/params";
import { logger } from "firebase-functions/v2";
import { SignJWT } from "jose";

// APNs .p8 auth key contents (PEM), key id, and team id from the Apple
// Developer portal. VoIP pushes must go directly to APNs — FCM cannot
// deliver apns-push-type: voip.
export const apnsKey = defineSecret("APNS_AUTH_KEY");
export const apnsKeyId = defineString("APNS_KEY_ID");
export const apnsTeamId = defineString("APNS_TEAM_ID");
// The app's bundle id; the VoIP topic is `<bundle>.voip`.
export const apnsBundleId = defineString("APNS_BUNDLE_ID");
// "production" for TestFlight/App Store builds, anything else = sandbox.
export const apnsEnv = defineString("APNS_ENV", { default: "sandbox" });

export interface CallPushPayload {
  callId: string;
  callerId: string;
  callerName: string;
  callerPhone: string;
  // "true"/"false" — FCM data values must be strings.
  video: string;
}

// APNs provider tokens are valid 20-60 min; cache and refresh at 45.
let cachedApnsJwt: { token: string; mintedAt: number } | null = null;

async function apnsProviderJwt(): Promise<string> {
  const now = Date.now();
  if (cachedApnsJwt && now - cachedApnsJwt.mintedAt < 45 * 60 * 1000) {
    return cachedApnsJwt.token;
  }
  const key = createPrivateKey(apnsKey.value());
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: apnsKeyId.value() })
    .setIssuedAt()
    .setIssuer(apnsTeamId.value())
    .sign(key);
  cachedApnsJwt = { token, mintedAt: now };
  return token;
}

/**
 * Sends an APNs VoIP push. The iOS app's PushKit handler MUST report a
 * CallKit call for every one of these, so they are sent for exactly one
 * event: a new ringing call. apns-expiration 0 = deliver now or drop —
 * never ring a stale call.
 */
export async function sendVoipPush(voipToken: string, payload: CallPushPayload): Promise<void> {
  const host =
    apnsEnv.value() === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
  const jwt = await apnsProviderJwt();

  await new Promise<void>((resolve, reject) => {
    const client = http2.connect(host);
    client.on("error", reject);
    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${voipToken}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": `${apnsBundleId.value()}.voip`,
      "apns-push-type": "voip",
      "apns-priority": "10",
      "apns-expiration": "0",
    });
    let status = 0;
    let body = "";
    req.on("response", (headers) => {
      status = Number(headers[":status"] ?? 0);
    });
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      client.close();
      if (status === 200) {
        resolve();
      } else {
        reject(new Error(`APNs ${status}: ${body}`));
      }
    });
    req.on("error", (err) => {
      client.close();
      reject(err);
    });
    req.end(JSON.stringify(payload));
  });
}

/**
 * Sends the Android incoming-call push: data-only, high priority so it
 * breaks Doze and the background isolate can show the full-screen ring.
 */
export async function sendFcmCallPush(fcmToken: string, payload: CallPushPayload): Promise<void> {
  await getMessaging().send({
    token: fcmToken,
    data: { type: "incoming_call", ...payload },
    android: { priority: "high", ttl: 45_000 },
  });
}

export function logPushFailure(kind: string, uid: string, err: unknown): void {
  logger.warn(`${kind} push failed for ${uid}`, { error: String(err) });
}
