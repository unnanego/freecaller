package com.unnanego.freecaller

import android.content.Intent
import com.google.firebase.messaging.RemoteMessage
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * Handles the `cancel_call` push natively.
 *
 * The plugin's programmatic dismiss (endCall/endAllCalls) never finishes the
 * full-screen incoming activity: its "ended" broadcast is component-targeted to
 * the Activity class, so the activity's dynamically-registered receiver never
 * receives it, and the ring plays on to the 45s timeout. So on cancel we send
 * that broadcast correctly (action + package, no component) and tear the ring
 * down via the shared plugin instance — which owns the ringtone. Every other
 * message is forwarded to the normal Flutter background handler.
 */
class FreecallerMessagingService : FlutterFirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["type"] == "cancel_call") {
            dismissIncoming()
            return
        }
        super.onMessageReceived(message)
    }

    private fun dismissIncoming() {
        try {
            sendBroadcast(
                Intent("$packageName.com.hiennv.flutter_callkit_incoming.ACTION_ENDED_CALL_INCOMING").apply {
                    setPackage(packageName)
                    putExtra("ACCEPTED", false)
                }
            )
        } catch (_: Exception) {}
        try {
            FlutterCallkitIncomingPlugin.getInstance()?.endAllCalls()
        } catch (_: Exception) {}
    }
}
