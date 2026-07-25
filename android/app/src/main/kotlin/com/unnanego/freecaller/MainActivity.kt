package com.unnanego.freecaller

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "freecaller/call_locks")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> { acquireLocks(); result.success(null) }
                    "release" -> { releaseLocks(); result.success(null) }
                    "setSpeaker" -> result.success(
                        setSpeaker(call.argument<Boolean>("on") ?: false),
                    )
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
    // The plugin drives routing through AudioManager.isSpeakerphoneOn, which is
    // deprecated since Android 12 and which several OEM builds quietly ignore
    // once a communication device has been selected — the symptom being a
    // speaker button that does nothing at all on those phones while working
    // everywhere else. setCommunicationDevice is the supported replacement and
    // is what actually moves the audio on them.
    //
    // Returns a description of what it did, so a device that refuses can be
    // told apart from one that was never asked.
    private fun setSpeaker(on: Boolean): String {
        val audio = applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            @Suppress("DEPRECATION")
            audio.isSpeakerphoneOn = on
            return "legacy isSpeakerphoneOn=$on"
        }

        val devices = audio.availableCommunicationDevices

        // A headset the user plugged in or paired outranks the speaker button:
        // blasting a call out of the loudspeaker when someone has earphones in
        // is worse than ignoring the toggle.
        val external = devices.firstOrNull {
            it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                it.type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
        }
        if (external != null) {
            return "left on external device (type=${'$'}{external.type})"
        }

        if (!on) {
            audio.clearCommunicationDevice()
            return "cleared -> platform default (earpiece)"
        }

        val speaker = devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            ?: return "no builtin speaker among ${'$'}{devices.map { it.type }}"

        val applied = audio.setCommunicationDevice(speaker)
        return "setCommunicationDevice(speaker)=$applied"
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
