import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { logger } from "firebase-functions/v2";

/**
 * When a user files an in-app child-safety report (`reports/{id}`), push a
 * display notification to every admin's devices so it can be actioned — not
 * just left sitting in Firestore. Uses a regular FCM notification (works on
 * both platforms); no APNs VoIP secret needed.
 */
export const onReportCreated = onDocumentCreated("reports/{reportId}", async (event) => {
  const report = event.data?.data();
  if (!report) return;
  const message = String(report.message ?? "").slice(0, 140);

  const db = getFirestore();
  const admins = await db.collection("users").where("isAdmin", "==", true).get();
  if (admins.empty) {
    logger.warn("Safety report filed but no admin users to notify");
    return;
  }

  const tokens: string[] = [];
  await Promise.all(
    admins.docs.map(async (admin) => {
      const devices = await admin.ref.collection("devices").get();
      for (const doc of devices.docs) {
        const token = doc.data().fcmToken as string | undefined;
        if (token) tokens.push(token);
      }
    })
  );

  if (tokens.length === 0) {
    logger.warn("Safety report filed but no admin devices registered");
    return;
  }

  await Promise.all(
    tokens.map((token) =>
      getMessaging()
        .send({
          token,
          notification: {
            title: "Новое сообщение о безопасности детей",
            body: message || "Откройте приложение, чтобы посмотреть.",
          },
          android: { priority: "high" },
        })
        .catch((err) => logger.warn("report push failed", { error: String(err) }))
    )
  );
});
