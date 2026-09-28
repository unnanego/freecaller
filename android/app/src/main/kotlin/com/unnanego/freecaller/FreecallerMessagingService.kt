package com.unnanego.freecaller

import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.RemoteMessage
import com.hiennv.flutter_callkit_incoming.CallkitIncomingActivity
import com.hiennv.flutter_callkit_incoming.CallkitIncomingBroadcastReceiver
import com.hiennv.flutter_callkit_incoming.Data
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
 * down with the plugin's own ENDED broadcast — sent from here, not through the
 * shared plugin instance, which does not exist in a process Flutter never
 * attached to (see dismissIncoming).
 *
 * That teardown is scoped to the call the push names. It used to end whatever
 * was ringing, which is only safe if cancels can't overtake rings — and they
 * can. A caller who gives up and immediately redials produces a cancel for call
 * N and a ring for call N+1 seconds apart, and FCM makes no ordering promise
 * between two separate messages, so on a slow link the cancel lands second and
 * killed the ring for a call that was very much still live. Matching on callId
 * makes a late cancel harmless.
 *
 * A cancel naming a call this device isn't showing has nothing to tear down
 * here. Note what the early `return` below does and does not do: it keeps the
 * message from FlutterFirebaseMessagingService's own handling in THIS service,
 * nothing more. It does not stop Dart from waking — firebase_messaging
 * dispatches background messages from its own manifest receiver
 * (FlutterFirebaseMessagingReceiver), which sees every FCM message regardless
 * of which service is registered for MESSAGING_EVENT. So the Dart background
 * handler still runs for a cancel; this class only makes sure the ring comes
 * down even when that isolate is slow, or never gets to start. Every other
 * message is forwarded to the normal Flutter handling.
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

        // 1. The full-screen activity, addressed BY CALL ID. With rings N and
        //    N+1 both stored, an id-less "ended" finished whichever was on
        //    screen — a cancel for N took down the live ring for N+1. The
        //    activity ignores an id that is not the one it is showing.
        try {
            sendBroadcast(CallkitIncomingActivity.getIntentEndedFor(this, callId, false))
        } catch (_: Exception) {}

        val active: List<Data> = try {
            getDataActiveCalls(this)
        } catch (_: Exception) {
            emptyList()
        }
        val ringing = active.firstOrNull { it.id.equals(callId, ignoreCase = true) }
        if (ringing == null) {
            // Not in the stored list, so as far as the plugin knows there is
            // no such ring. A notification can still be up (it outlives the
            // process and the prefs entry alike); cancelling an id that is not
            // posted is a no-op, so do it rather than reason about whether it
            // could be. Same id derivation as CallkitNotificationManager.
            try {
                NotificationManagerCompat.from(this).cancel(callId.hashCode())
            } catch (_: Exception) {}
            return
        }

        // 2. The plugin's ENDED broadcast, sent from HERE rather than through
        //    FlutterCallkitIncomingPlugin.getInstance()?.endCall(): that
        //    instance is null in a process with no Flutter engine — the ring's
        //    process died and this cancel started a fresh one — and the `?.`
        //    then skipped the whole teardown, leaving a dead "incoming call"
        //    the user could still press Answer on. endCall() is nothing but
        //    this broadcast anyway. The receiver cancels the notification (on
        //    its own when there is no plugin instance), stops the notification
        //    service, disconnects the Telecom connection if this process has
        //    one, and tells Dart if Dart is there to be told.
        try {
            sendBroadcast(CallkitIncomingBroadcastReceiver.getIntentEnded(this, ringing.toBundle()))
        } catch (_: Exception) {}
        // The receiver removes the stored entry too, but asynchronously and
        // only if it gets that far; do it here as well so a dead call never
        // sits in the active list for CallEngine's cold-start reconciliation
        // to trip over. Removing twice is harmless.
        try {
            removeCall(this, ringing)
        } catch (_: Exception) {}
    }
}
