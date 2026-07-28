package com.unnanego.freecaller

import android.content.Intent
import com.google.firebase.messaging.RemoteMessage
import com.hiennv.flutter_callkit_incoming.Data
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import com.hiennv.flutter_callkit_incoming.getDataActiveCalls
import com.hiennv.flutter_callkit_incoming.removeCall
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * Handles the `cancel_call` push natively.
 *
 * The plugin's programmatic dismiss (endCall/endAllCalls) never finishes the
 * full-screen incoming activity: its "ended" broadcast is component-targeted to
 * the Activity class, so the activity's dynamically-registered receiver never
 * receives it, and the ring plays on to the 45s timeout. So on cancel we send
 * that broadcast correctly (action + package, no component) and tear the ring
 * down via the shared plugin instance — which owns the ringtone.
 *
 * That teardown is scoped to the call the push names. It used to end whatever
 * was ringing, which is only safe if cancels can't overtake rings — and they
 * can. A caller who gives up and immediately redials produces a cancel for call
 * N and a ring for call N+1 seconds apart, and FCM makes no ordering promise
 * between two separate messages, so on a slow link the cancel lands second and
 * killed the ring for a call that was very much still live. Matching on callId
 * makes a late cancel harmless.
 *
 * A cancel naming a call this device isn't showing is simply dropped: there is
 * nothing to tear down, and waking a Flutter isolate to discover that costs a
 * process start on exactly the battery-restricted phones this matters on. The
 * engine learns the call ended from its own reconcile either way. Every other
 * message is forwarded to the normal Flutter background handler.
 */
class FreecallerMessagingService : FlutterFirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["type"] == "cancel_call") {
            dismissIncoming(message.data["callId"].orEmpty())
            return
        }
        super.onMessageReceived(message)
    }

    private fun dismissIncoming(callId: String) {
        if (callId.isEmpty()) return

        val active: List<Data> = try {
            getDataActiveCalls(this)
        } catch (_: Exception) {
            return
        }
        val ringing = active.firstOrNull { it.id == callId } ?: return

        try {
            sendBroadcast(
                Intent("$packageName.com.hiennv.flutter_callkit_incoming.ACTION_ENDED_CALL_INCOMING").apply {
                    setPackage(packageName)
                    putExtra("ACCEPTED", false)
                }
            )
        } catch (_: Exception) {}
        try {
            FlutterCallkitIncomingPlugin.getInstance()?.endCall(ringing)
        } catch (_: Exception) {}
        // The plugin instance is null when Flutter was never attached — the
        // cold case this whole path exists for — so drop the persisted entry
        // ourselves rather than leaving a dead call in the active list for
        // CallEngine's cold-start reconciliation to trip over.
        try {
            removeCall(this, ringing)
        } catch (_: Exception) {}
    }
}
