import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';

/// Sessions and account lifecycle, on PocketBase's passwordless email OTP.
///
/// The flow this replaced handed out a Firebase custom token to anyone who
/// could guess a 6-digit code from an unauthenticated, unthrottled endpoint —
/// 10⁶ tries away from taking over every account on the roster. Here the
/// credential is possession of the account's mailbox, and codes are single-use,
/// server-issued and short-lived.
///
/// Sign-in is two steps ([requestCode] then [signInWithCode]) because the code
/// arrives out of band, in an email.
class AuthService {
  AuthService(this._pb);

  static const _deviceIdKey = 'deviceId';

  final PocketBase _pb;

  RecordService get _users => _pb.collection(Config.pbUsersCollection);

  /// Signed in only if the stored token is still in date. A record left over
  /// from an expired session must read as signed out, or every request the app
  /// makes would 401 behind a home screen that looks fine.
  String? get _currentUid =>
      _pb.authStore.isValid ? _pb.authStore.record?.id : null;

  /// Emits the signed-in uid, or null when signed out. Emits the current value
  /// on listen — the app's root [StreamBuilder] shows a spinner until it does.
  Stream<String?> get authState async* {
    yield _currentUid;
    // Fires on save() and clear(), so it covers sign-in, sign-out, deletion and
    // every authRefresh(). distinct() keeps a refresh that changed nothing but
    // the expiry from rebuilding the app.
    yield* _pb.authStore.onChange.map((_) => _currentUid).distinct();
  }

  String? get uid => _currentUid;

  /// Stable per-install device id, minted on first launch. Keys the device
  /// record that holds this install's push tokens.
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  /// Step one: email a one-time code to [email], returning the id that ties the
  /// code to this attempt.
  ///
  /// PocketBase answers with an otpId even for an address that has no account,
  /// on purpose — it refuses to leak who is on the roster. A wrong address
  /// therefore fails at [signInWithCode], when no code ever arrives.
  Future<String> requestCode(String email) async {
    final otp = await _users.requestOTP(email.trim());
    return otp.otpId;
  }

  /// Step two: [otpId] from [requestCode] plus the code the user read out of
  /// their email. On success the token is stored and the [authState] stream
  /// flips the app to the home screen.
  Future<void> signInWithCode(String otpId, String code) async {
    await _users.authWithOTP(otpId, code.trim());
  }

  /// True when [error] means "wrong code" rather than "no connection" — the
  /// activation screen must never label an offline device a bad code (that was
  /// the App Store 2.1 rejection). A rejected code comes back as an HTTP error;
  /// an offline device comes back as statusCode 0, the SDK's placeholder for
  /// "the request never landed".
  bool isBadCredential(Object error) =>
      error is ClientException &&
      const {400, 401, 404}.contains(error.statusCode);

  /// Re-issues the token so its expiry moves forward — the client half of the
  /// "sessions never expire" design (`pb_migrations/…_infinite_sessions.js`).
  /// The 3-year server ceiling only helps if a device that is used regularly
  /// keeps pushing `exp` out.
  ///
  /// Failures are swallowed: offline is the common case and the stored token is
  /// still good for a long time. A token the server has genuinely rejected is a
  /// different matter — drop it, so the user lands on activation instead of on
  /// a home screen where nothing works.
  Future<void> refreshSession() async {
    if (!_pb.authStore.isValid) return;
    try {
      await _users.authRefresh();
    } on ClientException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) _pb.authStore.clear();
    } catch (_) {
      // Not a transport we understand; keep the session.
    }
  }

  /// Permanently deletes the account and all its data, then clears the local
  /// session (App Store Guideline 5.1.1(v)). No server function is involved:
  /// the delete rule lets the owner delete their own record, and the cascade
  /// plus `pb_hooks/users.pb.js` take the devices, rosters and call history
  /// with it.
  Future<void> deleteAccount() async {
    final id = _currentUid;
    if (id != null) await _users.delete(id);
    _pb.authStore.clear();
  }

  Future<void> signOut() async => _pb.authStore.clear();
}
