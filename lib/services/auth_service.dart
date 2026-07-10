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

  /// The app's only sign-in path: a one-time 6-digit code provisioned by
  /// the family admin, exchanged for a custom auth token. Sign-in persists
  /// for the life of the install — no re-login ever.
  Future<void> redeemActivationCode(String code) async {
    final result = await _functions.httpsCallable('redeemActivationCode').call({
      'code': code,
      'deviceId': await deviceId(),
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    await _auth.signInWithCustomToken(data['token'] as String);
  }
}
