import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AuthService {
  AuthService(this._auth, this._functions);

  static const _deviceIdKey = 'deviceId';

  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  Stream<User?> get authState => _auth.authStateChanges();
  String? get uid => _auth.currentUser?.uid;

  /// Stable per-install device id, minted on first launch. Keys the device
  /// doc that holds this install's push tokens.
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_deviceIdKey, id);
    }
    return id;
  }

  /// Sign in with a 6-digit code — either a one-time invite code or the user's
  /// permanent login code (shown in Settings, reusable on any device).
  Future<void> signInWithCode(String code) async {
    final result = await _functions.httpsCallable('signInWithCode').call({
      'code': code,
      'deviceId': await deviceId(),
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    await _auth.signInWithCustomToken(data['token'] as String);
  }

  /// Backfills a permanent login code for the signed-in user if they don't have
  /// one yet (existing accounts get one on next launch). Best-effort.
  Future<void> ensureLoginCode() async {
    try {
      await _functions.httpsCallable('ensureLoginCode').call();
    } catch (_) {
      // Non-fatal — Settings just won't show a code until it succeeds.
    }
  }

  Future<void> signOut() => _auth.signOut();
}
