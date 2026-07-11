import { initializeApp } from "firebase-admin/app";
import { setGlobalOptions } from "firebase-functions/v2";

initializeApp();

// Co-located with the europe-west3 Firestore database (required for the
// Firestore trigger) and closest to the users.
setGlobalOptions({ region: "europe-west3", maxInstances: 10 });

export { redeemActivationCode } from "./activation";
export { mintLiveKitToken } from "./livekit";
export { onCallCreated, sweepStaleCalls } from "./calls";
export { matchContacts } from "./contacts";
