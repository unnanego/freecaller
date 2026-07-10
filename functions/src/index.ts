import { initializeApp } from "firebase-admin/app";

initializeApp();

export { redeemActivationCode } from "./activation";
export { mintLiveKitToken } from "./livekit";
export { onCallCreated, sweepStaleCalls } from "./calls";
