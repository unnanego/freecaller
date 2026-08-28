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
  /// own APIs, alongside what the WebRTC plugin does.
  ///
  /// The plugin routes via the deprecated isSpeakerphoneOn, which some OEM
  /// builds ignore outright — a speaker button that does nothing on one phone
  /// and works on every other. This goes through setCommunicationDevice, the
  /// supported path since Android 12 — or, when [callId] is an answered call
  /// that Telecom is hosting, through that call's own Connection, which is the
  /// only thing that can move the audio while Telecom owns the route. It defers
  /// to a connected headset either way.
  ///
  /// iOS has its own handler on this channel (AppDelegate): CallKit hands the
  /// call a fresh AVAudioSession whose route is decided without reference to
  /// what the WebRTC plugin asked for, so the speaker has to be overridden on
  /// the session itself. This used to return early off Android, which is why a
  /// speaker chosen before connecting was ignored there — the native override
  /// was never even attempted.
  ///
  /// Returns the platform's account of what it did, for the log; null when the
  /// call failed or the platform has no handler.
  Future<String?> setSpeaker(bool on, {String? callId}) async {
    try {
      return await _channel
          .invokeMethod<String>('setSpeaker', {'on': on, 'callId': callId});
    } catch (e) {
      log('native setSpeaker($on) failed', error: e);
      return null;
    }
  }

  /// Keep the screen awake for as long as [on].
  ///
  /// Video only, at the call screen's discretion: a voice call blanks the
  /// screen against the ear by proximity instead, and on Android the two
  /// mechanisms fight — FLAG_KEEP_SCREEN_ON wins over the proximity wake lock
  /// and would leave the screen lit against someone's cheek.
  Future<void> setKeepScreenOn(bool on) async {
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {'on': on});
    } catch (e) {
      log('call locks: setKeepScreenOn($on) failed', error: e);
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
