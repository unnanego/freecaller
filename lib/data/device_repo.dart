import 'package:pocketbase/pocketbase.dart';

import '../core/config.dart';

/// This install's push registration in the `devices` collection — the tokens
/// the server rings (PushKit VoIP on iOS, FCM on Android).
///
/// Firestore keyed these by document id (users/{uid}/devices/{deviceId}), which
/// made re-registering a merge-set. PocketBase mints its own record ids, so the
/// install id is a field with a unique index, and upsert is find-then-write.
class DeviceRepo {
  DeviceRepo(this._pb);

  final PocketBase _pb;

  RecordService get _devices => _pb.collection(Config.pbDevicesCollection);

  /// Register (or update) this install's tokens for [uid].
  ///
  /// A token is only written when we have one: iOS registers a voipToken and
  /// Android an fcmToken, and each rotates independently, so a partial update
  /// must never blank the other.
  Future<void> upsert({
    required String uid,
    required String deviceId,
    required String platform,
    String? fcmToken,
    String? voipToken,
  }) async {
    final body = {
      'user': uid,
      'deviceId': deviceId,
      'platform': platform,
      'fcmToken': ?fcmToken,
      'voipToken': ?voipToken,
    };

    final existing = await _find(uid, deviceId);
    if (existing != null) {
      await _devices.update(existing.id, body: body);
      return;
    }
    // If this install was last registered to ANOTHER account, the create is
    // what hands it over: pb_hooks/devices.pb.js drops the previous row so the
    // phone stops ringing for the account it left.
    await _devices.create(body: body);
  }

  /// Remove this device's push registration so a signed-out device stops
  /// receiving calls for the account it just left.
  Future<void> delete({required String uid, required String deviceId}) async {
    final existing = await _find(uid, deviceId);
    if (existing != null) await _devices.delete(existing.id);
  }

  /// Our own registration, if we have one. The list rule scopes this to the
  /// signed-in user, so it can only ever return this account's row.
  Future<RecordModel?> _find(String uid, String deviceId) async {
    try {
      return await _devices.getFirstListItem(
        // Both values are ours: the server-issued uid and the id we minted.
        "user = '$uid' && deviceId = '$deviceId'",
      );
    } on ClientException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }
}
