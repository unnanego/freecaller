import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';

import '../core/log.dart';
import '../data/device_repo.dart';
import 'auth_service.dart';
import 'call_ui/call_ui.dart';

/// Collects this install's push tokens (FCM on Android, PushKit VoIP on
/// iOS) and keeps the device doc current: re-uploads on every cold start
/// and on token rotation.
class PushRegistrar {
  PushRegistrar(this._auth, this._devices, this._callUi);

  final AuthService _auth;
  final DeviceRepo _devices;
  final CallUi _callUi;

  StreamSubscription<String>? _fcmRotation;
  StreamSubscription<CallUiEvent>? _voipRotation;

  Future<void> register() async {
    final uid = _auth.uid;
    if (uid == null) return;
    final deviceId = await _auth.deviceId();

    if (Platform.isAndroid) {
      // Don't rely on a single getToken(): on a fresh install it can transiently
      // return null / throw (Play Services or network still warming up), which
      // would leave the device unregistered and unreachable for calls until a
      // token rotation. Retry a few times; onTokenRefresh is the ongoing backstop.
      unawaited(_uploadFcmWithRetry(uid, deviceId));
      _fcmRotation ??= FirebaseMessaging.instance.onTokenRefresh.listen(
        (token) => _upload(uid, deviceId, fcmToken: token),
      );
    }

    if (Platform.isIOS) {
      final token = await _callUi.voipToken();
      if (token != null) await _upload(uid, deviceId, voipToken: token);
      _voipRotation ??= _callUi.events
          .where((e) => e.type == CallUiEventType.voipTokenUpdated)
          .listen((e) {
        final token = e.extra?['token'] as String?;
        if (token != null && token.isNotEmpty) {
          _upload(uid, deviceId, voipToken: token);
        }
      });
    }
  }

  /// Drop this device's push registration for the current account (called on
  /// sign-out) so it stops ringing for a call to an account it has left.
  Future<void> unregister() async {
    await _fcmRotation?.cancel();
    _fcmRotation = null;
    await _voipRotation?.cancel();
    _voipRotation = null;
    final uid = _auth.uid;
    if (uid == null) return;
    try {
      await _devices.delete(uid: uid, deviceId: await _auth.deviceId());
    } catch (e) {
      log('push token unregister failed', error: e);
    }
  }

  /// Fetch the FCM token with retries and register it — a fresh install often
  /// isn't ready to hand one out on the very first call.
  Future<void> _uploadFcmWithRetry(String uid, String deviceId) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) {
          await _upload(uid, deviceId, fcmToken: token);
          return;
        }
      } catch (e) {
        log('fcm getToken attempt ${attempt + 1} failed', error: e);
      }
      await Future<void>.delayed(Duration(seconds: (attempt + 1) * 2));
    }
    log('fcm getToken: still no token after retries (onTokenRefresh will cover)');
  }

  Future<void> _upload(String uid, String deviceId,
      {String? fcmToken, String? voipToken}) async {
    try {
      await _devices.upsert(
        uid: uid,
        deviceId: deviceId,
        platform: Platform.isIOS ? 'ios' : 'android',
        fcmToken: fcmToken,
        voipToken: voipToken,
      );
    } catch (e) {
      log('push token upload failed', error: e);
    }
  }
}
