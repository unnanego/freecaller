import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions/v2";
import {
  apnsKey,
  CallPushPayload,
  logPushFailure,
  sendFcmCallPush,
  sendFcmCancel,
  sendVoipCancel,
  sendVoipPush,
} from "./push";

/**
 * Fans the incoming-call push out to every device of the callee as soon as
 * the caller creates the ringing call doc. iOS devices get an APNs VoIP
 * push, Android devices an FCM high-priority data message.
 */
export const onCallCreated = onDocumentCreated(
  { document: "calls/{callId}", secrets: [apnsKey] },
  async (event) => {
    const call = event.data?.data();
    if (!call || call.state !== "ringing") return;

    const payload: CallPushPayload = {
      callId: event.params.callId,
      callerId: call.callerId,
      callerName: call.callerName ?? "",
      callerPhone: call.callerPhone ?? "",
      video: call.isVideo === true ? "true" : "false",
    };

    const devices = await getFirestore()
      .collection("users")
      .doc(call.calleeId)
      .collection("devices")
      .get();

    if (devices.empty) {
      logger.warn(`Callee ${call.calleeId} has no registered devices`);
      return;
    }

    await Promise.all(
      devices.docs.map(async (doc) => {
        const d = doc.data();
        try {
          if (d.platform === "ios" && d.voipToken) {
            await sendVoipPush(d.voipToken, payload);
          } else if (d.platform === "android" && d.fcmToken) {
            await sendFcmCallPush(d.fcmToken, payload);
          }
        } catch (err) {
          logPushFailure(d.platform, call.calleeId, err);
        }
      })
    );
  }
);

/**
 * When a still-ringing call is ended before the callee answered (the caller
 * cancelled, or the sweep marked it missed), push the callee's devices to
 * dismiss the ring — otherwise it rings on to the 45s timeout. `declined` is
 * the callee's own action, so their ring is already gone; skip it.
 */
export const onCallEnded = onDocumentUpdated(
  { document: "calls/{callId}", secrets: [apnsKey] },
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;
    if (before.state !== "ringing") return;
    if (after.state !== "cancelled" && after.state !== "missed") return;

    const callId = event.params.callId;
    const devices = await getFirestore()
      .collection("users")
      .doc(after.calleeId)
      .collection("devices")
      .get();

    await Promise.all(
      devices.docs.map(async (doc) => {
        const d = doc.data();
        try {
          if (d.platform === "ios" && d.voipToken) {
            await sendVoipCancel(d.voipToken, callId);
          } else if (d.platform === "android" && d.fcmToken) {
            await sendFcmCancel(d.fcmToken, callId);
          }
        } catch (err) {
          logPushFailure(d.platform, after.calleeId, err);
        }
      })
    );
  }
);

/**
 * Fallback authority for missed calls: normally the caller's 45s timer
 * writes `missed`, but if the caller crashed or went offline the ringing
 * doc would dangle forever — and the callee's UI trusts the doc.
 */
export const sweepStaleCalls = onSchedule("every 1 minutes", async () => {
  const db = getFirestore();
  const stale = await db
    .collection("calls")
    .where("state", "==", "ringing")
    .where("ringExpiresAt", "<", Timestamp.now())
    .get();

  await Promise.all(
    stale.docs.map((doc) =>
      doc.ref.update({ state: "missed", endedAt: Timestamp.now() })
    )
  );
  if (!stale.empty) {
    logger.info(`Swept ${stale.size} stale ringing call(s) to missed`);
  }
});
