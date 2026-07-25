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

  /// Force the call audio onto the loudspeaker (or off it) through Android's
  /// own AudioManager, alongside what the WebRTC plugin does.
  ///
  /// The plugin routes via the deprecated isSpeakerphoneOn, which some OEM
  /// builds ignore outright — a speaker button that does nothing on one phone
  /// and works on every other. This goes through setCommunicationDevice, the
  /// supported path since Android 12. It defers to a connected headset.
  ///
  /// Returns the platform's account of what it did, for the log; null off
  /// Android or when the call failed.
  Future<String?> setSpeaker(bool on) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _channel.invokeMethod<String>('setSpeaker', {'on': on});
    } catch (e) {
      log('native setSpeaker($on) failed', error: e);
      return null;
    }
  }

  Future<void> _invoke(String method) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      log('call locks: $method failed', error: e);
    }
  }
}
