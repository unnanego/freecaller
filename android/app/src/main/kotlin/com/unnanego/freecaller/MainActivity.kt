package com.unnanego.freecaller

import android.content.Context
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

    private fun releaseLocks() {
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}
