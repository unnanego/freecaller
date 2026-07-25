import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pocketbase/pocketbase.dart';

class UserProfile {
  const UserProfile({
    required this.uid,
    required this.phone,
    required this.displayName,
    required this.contactUids,
  });

  final String uid;
  final String phone;
  final String displayName;
  final List<String> contactUids;

  factory UserProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return UserProfile(
      uid: doc.id,
      phone: data['phone'] as String? ?? '',
      displayName: data['displayName'] as String? ?? '',
      contactUids: List<String>.from(data['contacts'] as List? ?? const []),
    );
  }
}

class Contact {
  const Contact({required this.uid, required this.displayName, required this.phone});

  final String uid;
  final String displayName;
  final String phone;
}

enum CallState { ringing, accepted, declined, cancelled, missed, ended }

CallState callStateFrom(String? raw) =>
    CallState.values.firstWhere((s) => s.name == raw, orElse: () => CallState.ended);

class CallDoc {
  const CallDoc({
    required this.callId,
    required this.callerId,
    required this.calleeId,
    required this.callerName,
    required this.callerPhone,
    required this.isVideo,
    required this.state,
    required this.createdAt,
  });

  final String callId;
  final String callerId;
  final String calleeId;
  final String callerName;
  final String callerPhone;
  final bool isVideo;
  final CallState state;
  final DateTime? createdAt;

  factory CallDoc.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return CallDoc(
      callId: doc.id,
      callerId: data['callerId'] as String? ?? '',
      calleeId: data['calleeId'] as String? ?? '',
      callerName: data['callerName'] as String? ?? '',
      callerPhone: data['callerPhone'] as String? ?? '',
      isVideo: data['isVideo'] as bool? ?? false,
      state: callStateFrom(data['state'] as String?),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  /// PocketBase counterpart of [CallDoc.fromDoc]. `createdAt` comes from the
  /// record's own `created` autodate rather than a field we write.
  factory CallDoc.fromRecord(RecordModel record) => CallDoc(
        callId: record.id,
        callerId: record.get<String>('callerId', ''),
        calleeId: record.get<String>('calleeId', ''),
        callerName: record.get<String>('callerName', ''),
        callerPhone: record.get<String>('callerPhone', ''),
        isVideo: record.get<bool>('isVideo', false),
        state: callStateFrom(record.get<String>('state', '')),
        createdAt: DateTime.tryParse(record.get<String>('created', '')),
      );

  /// Value equality lets a watch skip re-emitting an unchanged call — needed
  /// because the PocketBase repo reconciles on a timer and would otherwise
  /// churn the engine every few seconds.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallDoc &&
          other.callId == callId &&
          other.callerId == callerId &&
          other.calleeId == calleeId &&
          other.callerName == callerName &&
          other.callerPhone == callerPhone &&
          other.isVideo == isVideo &&
          other.state == state &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(callId, callerId, calleeId, callerName,
      callerPhone, isVideo, state, createdAt);
}
