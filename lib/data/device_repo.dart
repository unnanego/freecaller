import 'package:cloud_firestore/cloud_firestore.dart';

class DeviceRepo {
  DeviceRepo(this._db);

  final FirebaseFirestore _db;

  Future<void> upsert({
    required String uid,
    required String deviceId,
    required String platform,
    String? fcmToken,
    String? voipToken,
  }) {
    return _db.collection('users').doc(uid).collection('devices').doc(deviceId).set({
      'platform': platform,
      'fcmToken': ?fcmToken,
      'voipToken': ?voipToken,
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));
  }
}
