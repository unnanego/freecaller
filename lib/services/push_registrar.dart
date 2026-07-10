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
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _upload(uid, deviceId, fcmToken: token);
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
