/// App-wide constants.
abstract final class Config {
  /// How long an outgoing call rings before the caller marks it missed.
  /// Mirrored server-side by ringExpiresAt + the stale-call sweep.
  static const ringTimeout = Duration(seconds: 45);

  /// Cloud Functions region (keep in sync with functions deployment).
  static const functionsRegion = 'europe-west3';

  /// MethodChannel name for the iOS intents bridge (Siri → Dart).
  static const intentsChannel = 'freecaller/intents';
}
