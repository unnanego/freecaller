package com.unnanego.freecaller

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.telecom.CallAudioState
import android.util.Log
import android.view.WindowManager
import com.hiennv.flutter_callkit_incoming.CallkitConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        // Audio routing is the one thing here that can only be diagnosed on the
        // phone that misbehaves, and Dart's log() is compiled out of release
        // builds — so these go through android.util.Log, which a release build
        // still emits. `adb logcat -s FreecallerAudio` during one call says
        // exactly which branch ran and where the audio actually went.
        private const val AUDIO_TAG = "FreecallerAudio"

        private val EXTERNAL_TYPES = setOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "freecaller/call_locks")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> { acquireLocks(); result.success(null) }
                    "release" -> { releaseLocks(); result.success(null) }
                    "setKeepScreenOn" -> {
                        setKeepScreenOn(call.argument<Boolean>("on") ?: false)
                        result.success(null)
                    }
                    "setSpeaker" -> {
                        val outcome = setSpeaker(
                            call.argument<Boolean>("on") ?: false,
                            call.argument<String>("callId"),
                        )
                        Log.i(AUDIO_TAG, "-> $outcome")
                        result.success(outcome)
                    }
                    else -> result.notImplemented()
                }
            }

        // Profile photos go through our own activity rather than a plugin's
        // activity result — see PhotoPickerActivity for why this app cannot use
        // the ordinary path.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "freecaller/photo_picker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> {
                        PhotoPickerBridge.begin(result)
                        val intent = Intent(this, PhotoPickerActivity::class.java)
                            .putExtra(
                                PhotoPickerActivity.EXTRA_CAMERA,
                                call.argument<Boolean>("camera") ?: false,
                            )
                            // Started from a singleInstance activity, so it gets
                            // its own task either way; saying so keeps the
                            // platform from complaining about it.
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Keep the Wi-Fi radio and CPU at full performance for the duration of a
    // call. The outgoing side deliberately never registers a telecom call (that
    // oscillates the audio route), so it has no foreground service holding the
    // radio awake — and on battery, Wi-Fi power-save then starves WebRTC ICE, so
    // the media connection times out / drops a few seconds in. These locks
    // prevent that; they touch neither audio focus nor routing.
    private fun acquireLocks() {
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            // LOW_LATENCY (API 29+) disables power-save and minimises latency while
            // foreground; HIGH_PERF is the pre-29 equivalent (just no power-save).
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "freecaller:call")
        }
        wifiLock?.takeIf { !it.isHeld }?.acquire()

        if (wakeLock == null) {
            val power = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "freecaller:call")
        }
        // 1h safety cap so a missed release can never drain the battery indefinitely.
        wakeLock?.takeIf { !it.isHeld }?.acquire(60 * 60 * 1000L)
    }

    // Route call audio to the speaker (or back off it), using the platform's
    // own API rather than the WebRTC plugin's device switcher.
    //
    // This is a FALLBACK, not a competitor. The plugin drives routing through
    // AudioManager.isSpeakerphoneOn, which is deprecated since Android 12 and
    // which several OEM builds quietly ignore once a communication device has
    // been selected — the symptom being a speaker button that does nothing at
    // all on those phones while working everywhere else. setCommunicationDevice
    // is the supported replacement and is what actually moves the audio there.
    //
    // But on the phones where the plugin path DOES work, calling it as well is
    // actively harmful: setCommunicationDevice/clearCommunicationDevice fire
    // OnCommunicationDeviceChanged, and the plugin's own device switcher
    // re-decides the route when it sees that — putting a Pixel straight back on
    // the earpiece a moment after the speaker button was pressed. So we look at
    // where the audio actually is first, and only intervene when the caller's
    // request has not already been honoured.
    //
    // Returns a description of what it did, so a phone that refuses can be told
    // apart from one that was never asked, and both from one that needed
    // nothing.
    //
    // The report is one self-contained human-readable line — phone, API level,
    // what was asked, the audio state either side of the attempt — because it is
    // read by eye, in a terminal, by someone who cannot touch the device: the
    // phone that gets this wrong is in another country and only ever updated
    // through Play, so Dart hands this string to the server (DiagnosticsRepo).
    private fun setSpeaker(on: Boolean, callId: String?): String {
        val audio = applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val before = audioState(audio)
        val outcome = applySpeaker(on, callId, audio)
        // The "after" state is read immediately, so a route the platform is still
        // in the middle of applying can legitimately lag it by a beat.
        return "${Build.MANUFACTURER} ${Build.MODEL} api=${Build.VERSION.SDK_INT} " +
            "want=${if (on) "speaker" else "earpiece"} | before: $before | " +
            "$outcome | after: ${audioState(audio)}"
    }

    // Everything about the current route worth knowing, with the device types
    // spelled out — a bare "type=2" is unreadable at a distance.
    private fun audioState(audio: AudioManager): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return "mode=${audio.mode}"
        val current = audio.communicationDevice
        val available = audio.availableCommunicationDevices.map { typeName(it.type) }
        return "mode=${audio.mode} current=${typeName(current?.type)} " +
            "routed=${routedVoiceTypes(audio).map { typeName(it) }} available=$available"
    }

    private fun typeName(type: Int?): String = when (type) {
        null -> "none"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired-headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired-headphones"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb-headset"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bt-sco"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bt-a2dp"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "ble-headset"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "ble-speaker"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing-aid"
        else -> "type$type"
    }

    private fun applySpeaker(on: Boolean, callId: String?, audio: AudioManager): String {
        // An ANSWERED call is a self-managed Telecom call here (the ring is
        // registered through CallkitConnectionService so it can bypass the
        // keyguard on strict OEMs), and Telecom owns the audio route for as
        // long as that call is up: its route state machine re-applies its own
        // choice, so everything below is at best advisory and on some builds
        // (Honor/Magic OS) ignored outright. Connection.setAudioRoute is the
        // supported way to move a Telecom call's audio.
        //
        // Strictly THIS call's connection. A connection belonging to some other
        // call is a leftover, and routing its audio would do nothing for the
        // call the user is actually on (CallEngine sweeps those away when a
        // call starts).
        routeViaTelecom(on, callId)?.let { return it }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = on
            return "legacy isSpeakerphoneOn=$on"
        }

        val devices = audio.availableCommunicationDevices
        val current = audio.communicationDevice
        // Where the audio ACTUALLY is, asked of the routing layer rather than of
        // the communication-device bookkeeping (Android 14+ only).
        val routed = routedVoiceTypes(audio)

        // Where the call is being heard, best available answer: the explicitly
        // selected device, else what the routing layer says, else nothing.
        val activeType = current?.type ?: routed.firstOrNull()

        // The plugin ran just before us. If it already got us where we want to
        // be, touching the route again only invites it to re-decide.
        //
        // "Already there" has to mean the audio, not the bookkeeping. Some OEM
        // builds accept the request, report the speaker as the communication
        // device, and go on playing out of the earpiece — and this early return
        // then swallowed every press, which is a speaker button that has never
        // worked once rather than one that works on most phones. So the claim
        // is only believed when the routing layer backs it up (or when the
        // routing layer can't be asked, pre-34).
        val claimsSpeaker = current?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        val reallyOnSpeaker = if (routed.isEmpty()) {
            claimsSpeaker
        } else {
            routed.contains(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER)
        }
        if (on == claimsSpeaker && on == reallyOnSpeaker) {
            return "already ${if (on) "on" else "off"} speaker via plugin"
        }

        // A headset the user plugged in or paired outranks the speaker button:
        // blasting a call out of the loudspeaker when someone has earphones in
        // is worse than ignoring the toggle.
        //
        // Only one the audio is actually ON, though. This used to bail whenever
        // an external device was merely AVAILABLE, and availability includes
        // every connected Bluetooth device — a watch, a paired speaker in
        // another room — none of which the call is going through. One such
        // device parked the speaker button permanently.
        if (activeType != null && activeType in EXTERNAL_TYPES) {
            return "left on external device (${typeName(activeType)})"
        }
        if (activeType == null) {
            // Nothing to inspect (pre-34 with no explicit selection): fall back
            // to the old, cautious rule.
            val available = devices.firstOrNull { it.type in EXTERNAL_TYPES }
            if (available != null) {
                return "left on available external device (${typeName(available.type)})"
            }
        }

        if (!on) {
            audio.clearCommunicationDevice()
            return "cleared -> platform default (earpiece)"
        }

        val speaker = devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            ?: return "no builtin speaker to select"

        val applied = audio.setCommunicationDevice(speaker)
        return "setCommunicationDevice(speaker)=$applied"
    }

    // The device types the platform says a voice call would currently be heard
    // through. Android 14+; empty everywhere else, and empty is "don't know",
    // never "nothing".
    private fun routedVoiceTypes(audio: AudioManager): List<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return emptyList()
        return try {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            audio.getAudioDevicesForAttributes(attributes).map { it.type }
        } catch (e: Throwable) {
            emptyList()
        }
    }

    // Move the audio of this call's self-managed Telecom connection, if it has
    // one. Returns null when Telecom is not in the picture — outgoing calls
    // (never registered, see CallKitCallUi.startOutgoing), or a phone where
    // addNewIncomingCall was refused — so the caller can fall back.
    private fun routeViaTelecom(on: Boolean, callId: String?): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        if (callId.isNullOrEmpty()) return null
        val connection = try {
            CallkitConnection.find(callId)
        } catch (e: Throwable) {
            null
        } ?: return null

        val current = connection.callAudioState?.route
        // Same rule as the AudioManager path: a headset the user is actually
        // wearing outranks the speaker button.
        if (current == CallAudioState.ROUTE_BLUETOOTH ||
            current == CallAudioState.ROUTE_WIRED_HEADSET
        ) {
            return "telecom: left on external route=$current"
        }
        val want = if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_EARPIECE
        return try {
            connection.setAudioRoute(want)
            "telecom setAudioRoute(${if (on) "speaker" else "earpiece"}) was=$current"
        } catch (e: Exception) {
            "telecom setAudioRoute failed: ${e.message}"
        }
    }

    // Hold the screen awake for a video call. Not for voice: there the screen is
    // deliberately blanked against the ear by the proximity wake lock, and this
    // flag outranks it — the screen would stay lit against a cheek.
    private fun setKeepScreenOn(on: Boolean) {
        runOnUiThread {
            if (on) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private fun releaseLocks() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}
