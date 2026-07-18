import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';

/// Holds an Android high-performance Wi-Fi lock + partial wake lock for the
/// duration of a call.
///
/// The outgoing/caller side never registers a telecom call (that oscillates the
/// audio route), so it has no foreground service keeping the radio awake — and
/// on battery, Wi-Fi power-save then starves WebRTC ICE, so the media connection
/// times out or drops a few seconds in. These locks keep the radio and CPU at
/// full performance while a call is active. No-op off Android; best-effort so a
/// lock failure can never break the call flow.
class CallLocks {
  static const _channel = MethodChannel('freecaller/call_locks');

  Future<void> acquire() => _invoke('acquire');
  Future<void> release() => _invoke('release');

  Future<void> _invoke(String method) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      log('call locks: $method failed', error: e);
    }
  }
}
