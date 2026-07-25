/// App-wide constants.
abstract final class Config {
  /// How long an outgoing call rings before the caller marks it missed.
  /// Mirrored server-side by ringExpiresAt + the stale-call sweep.
  static const ringTimeout = Duration(seconds: 45);

  /// Cloud Functions region (keep in sync with functions deployment).
  static const functionsRegion = 'europe-west3';

  /// MethodChannel name for the iOS intents bridge (Siri → Dart).
  static const intentsChannel = 'freecaller/intents';

  /// Self-hosted PocketBase base URL (migration target; unused while the
  /// Firestore repos are wired up in main()).
  static const pbUrl = String.fromEnvironment(
    'PB_URL',
    defaultValue: 'http://127.0.0.1:8090',
  );

  /// PocketBase collection holding call signaling records.
  static const pbCallsCollection = 'calls';

  /// How often a PocketBase call watch re-checks the server. PocketBase
  /// realtime never replays events missed while disconnected, so this is the
  /// backstop that converges state after a drop. Short, because a call that
  /// hangs in the wrong state is the worst failure this app has.
  static const callReconcileInterval = Duration(seconds: 5);
}
