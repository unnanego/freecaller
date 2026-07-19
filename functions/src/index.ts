import { initializeApp } from "firebase-admin/app";
import { setGlobalOptions } from "firebase-functions/v2";

initializeApp();

// Co-located with the europe-west3 Firestore database (required for the
// Firestore trigger) and closest to the users.
setGlobalOptions({ region: "europe-west3", maxInstances: 10 });

export { redeemActivationCode } from "./activation";
export { inviteContact } from "./invite";
export { signInWithCode, ensureLoginCode } from "./auth";
export { deleteAccount } from "./account";
export { mintLiveKitToken } from "./livekit";
export { onCallCreated, onCallEnded, sweepStaleCalls } from "./calls";
export { dedupeDeviceToken } from "./devices";
export { matchContacts } from "./contacts";
export { onReportCreated } from "./reports";
