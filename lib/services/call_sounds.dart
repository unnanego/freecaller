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
          // VOICE_COMMUNICATION_SIGNALLING, not VOICE_COMMUNICATION: the first
          // is Android's usage for call-PROGRESS tones (ringback, DTMF), the
          // second is for the call audio itself. Sharing the usage with the live
          // WebRTC stream made the tone inaudible on a Pixel even though it was
          // playing and holding focus — the route was right, nothing came out.
          //
          // It still follows the communication device, so the in-call speaker
          // toggle continues to move it (USAGE_MEDIA could not, and
          // NOTIFICATION_RINGTONE is the incoming-ringtone stream, which does
          // not follow the route either). Google's own Meet/Duo plays its call
          // tones on this usage — visible as VoiceCommunicationSignalling in
          // `dumpsys audio` next to ours.
          usageType: AndroidUsageType.voiceCommunicationSignalling,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      );

  /// Apply the context to the ringback player ITSELF, not just globally.
  ///
  /// `AudioPlayer.global.setAudioContext` only sets the default for players
  /// created afterwards, and both players here are field initialisers — so the
  /// global call never reached them and they kept audioplayers' defaults. On
  /// Android the focus request is built from the PER-PLAYER context, and the
  /// default is USAGE_MEDIA / CONTENT_TYPE_MUSIC / AUDIOFOCUS_GAIN.
  ///
  /// Two consequences, both observed on a Pixel 7 Pro: the ringback played on
  /// the media stream, which does not follow the communication device, so the
  /// in-call speaker toggle could not move it; and the tone took audio focus
  /// with a permanent GAIN, which hands the live WebRTC session an
  /// AUDIOFOCUS_LOSS instead of the transient duck this asks for.
  Future<void> _applyContext() async {
    final context = _context();
    try {
      await AudioPlayer.global.setAudioContext(context);
      await _ringback.setAudioContext(context);
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
      // Same per-player rule as _applyContext: the global default does not
      // reach a player that already exists.
      final context = AudioContext(
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
      );
      await AudioPlayer.global.setAudioContext(context);
      await _effect.setAudioContext(context);
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
