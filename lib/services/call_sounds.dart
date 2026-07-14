import 'package:audioplayers/audioplayers.dart';

import '../core/log.dart';

/// Call tones: an outgoing ringback loop while we wait for the callee to answer,
/// and a short cue when a call ends.
///
/// The audio context mixes with others (iOS) / ducks (Android) so these tones
/// overlay the live WebRTC/CallKit session instead of seizing it — this app's
/// call audio routing is fragile and must not be reset by a tone. The context
/// is only (re)applied while the ringback is actually playing, so a live
/// connected call's routing is never disturbed.
class CallSounds {
  final AudioPlayer _ringback = AudioPlayer();
  final AudioPlayer _effect = AudioPlayer();
  bool _speaker = false;
  bool _ringbackActive = false;

  AudioContext _context() => AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: {
            AVAudioSessionOptions.mixWithOthers,
            AVAudioSessionOptions.allowBluetooth,
            // Follow the in-call speaker toggle: earpiece by default, speaker
            // when the user turns it on.
            if (_speaker) AVAudioSessionOptions.defaultToSpeaker,
          },
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: _speaker,
          audioMode: AndroidAudioMode.inCommunication,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.voiceCommunication,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      );

  Future<void> _applyContext() async {
    try {
      await AudioPlayer.global.setAudioContext(_context());
    } catch (e) {
      log('call sounds: setAudioContext failed', error: e);
    }
  }

  /// Loop the ringback tone (caller waiting for an answer). Always starts on the
  /// earpiece default; the caller re-applies the speaker route via [setSpeaker]
  /// so the exact (working) toggle path drives any speaker-first state too.
  Future<void> startRingback() async {
    _speaker = false;
    _ringbackActive = true;
    await _applyContext();
    try {
      await _ringback.setReleaseMode(ReleaseMode.loop);
      await _ringback.setVolume(0.55);
      await _ringback.play(AssetSource('sounds/ringback.wav'));
    } catch (e) {
      log('call sounds: ringback failed', error: e);
    }
  }

  Future<void> stopRingback() async {
    _ringbackActive = false;
    try {
      await _ringback.stop();
    } catch (_) {}
  }

  /// Move the ringback between earpiece and speaker when the user toggles it.
  /// No-op unless the ringback is currently playing, so a connected call's
  /// audio session is never touched.
  Future<void> setSpeaker(bool on) async {
    if (_speaker == on) return;
    _speaker = on;
    if (!_ringbackActive) return;
    await _applyContext();
    // Restart the loop so the new route takes effect immediately.
    try {
      await _ringback.stop();
      await _ringback.setReleaseMode(ReleaseMode.loop);
      await _ringback.play(AssetSource('sounds/ringback.wav'));
    } catch (e) {
      log('call sounds: ringback reroute failed', error: e);
    }
  }

  /// One-shot tone when a call ends. Plays through a fresh playback session:
  /// by teardown the call's audio session is being deactivated (CallKit/WebRTC),
  /// so we wait a beat for that to settle, then activate a plain playback
  /// context so the tone is audible regardless of the prior route.
  Future<void> playEnded() async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await AudioPlayer.global.setAudioContext(AudioContext(
        // Exclusive playback (no mixWithOthers): after a speaker call the torn-
        // down session's route lingers, and mixing into it plays silently — an
        // exclusive activation forces a fresh route so the tone is always heard.
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {},
        ),
        android: AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ));
      await _effect.stop();
      await _effect.setVolume(1.0);
      await _effect.play(AssetSource('sounds/call_end.wav'));
    } catch (e) {
      log('call sounds: end tone failed', error: e);
    }
  }

  Future<void> dispose() async {
    try {
      await _ringback.dispose();
    } catch (_) {}
    try {
      await _effect.dispose();
    } catch (_) {}
  }
}
