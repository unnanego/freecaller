/// App-wide constants.
abstract final class Config {
  /// How long an outgoing call rings before the caller marks it missed.
  /// Mirrored server-side by ringExpiresAt + the stale-call sweep.
  static const ringTimeout = Duration(seconds: 45);

  /// MethodChannel name for the iOS intents bridge (Siri → Dart).
  static const intentsChannel = 'freecaller/intents';

  /// Self-hosted PocketBase base URL — the whole backend except push delivery.
  ///
  /// Defaults to production, so a release build is never silently pointed at a
  /// server that isn't there. Override for a local server with
  /// `--dart-define=PB_URL=http://127.0.0.1:8090`.
  static const pbUrl = String.fromEnvironment(
    'PB_URL',
    defaultValue: 'https://pb.holographica.space',
  );

  /// PocketBase collection holding call signaling records.
  static const pbCallsCollection = 'calls';

  /// PocketBase auth collection holding the roster: profile and credential are
  /// the same record here, unlike Firestore's users doc + Auth user pair.
  static const pbUsersCollection = 'users';

  /// PocketBase collection holding child-safety reports.
  static const pbReportsCollection = 'reports';

  /// PocketBase collection holding per-install push registrations.
  static const pbDevicesCollection = 'devices';

  /// Custom PocketBase routes (pb_hooks), for the things collection rules
  /// cannot express: minting a room token, and reading the whole roster to
  /// match contacts or provision an invitee.
  static const pbLiveKitTokenPath = '/api/freecaller/livekit-token';
  static const pbMatchContactsPath = '/api/freecaller/match-contacts';
  static const pbInvitePath = '/api/freecaller/invite';

  /// Moving the account to another mailbox: the first route mails a code to the
  /// new address, the second applies the change once it comes back.
  static const pbEmailChangeRequestPath = '/api/freecaller/email-change/request';
  static const pbEmailChangeConfirmPath = '/api/freecaller/email-change/confirm';

  /// How often a PocketBase profile watch re-reads the roster. Far slower than
  /// [callReconcileInterval] — a contact added by the admin can wait a minute,
  /// a call in the wrong state cannot.
  static const profileReconcileInterval = Duration(minutes: 2);

  /// How often a PocketBase call watch re-checks the server. PocketBase
  /// realtime never replays events missed while disconnected, so this is the
  /// backstop that converges state after a drop. Short, because a call that
  /// hangs in the wrong state is the worst failure this app has.
  static const callReconcileInterval = Duration(seconds: 5);
}
