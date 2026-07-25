import 'package:flutter/foundation.dart';
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

  /// `contacts` is a relation field, which the API serialises as a list of
  /// record ids.
  factory UserProfile.fromRecord(RecordModel record) => UserProfile(
        uid: record.id,
        phone: record.get<String>('phone', ''),
        displayName: record.get<String>('displayName', ''),
        contactUids: record.get<List<dynamic>>('contacts', const []).cast<String>(),
      );

  /// Value equality so a repo that re-reads the profile on a timer can drop
  /// unchanged reads instead of rebuilding the shell and re-teaching Siri.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          other.uid == uid &&
          other.phone == phone &&
          other.displayName == displayName &&
          listEquals(other.contactUids, contactUids);

  @override
  int get hashCode => Object.hash(uid, phone, displayName, Object.hashAll(contactUids));
}

class Contact {
  const Contact({required this.uid, required this.displayName, required this.phone});

  final String uid;
  final String displayName;
  final String phone;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Contact &&
          other.uid == uid &&
          other.displayName == displayName &&
          other.phone == phone;

  @override
  int get hashCode => Object.hash(uid, displayName, phone);
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

  /// `createdAt` comes from the record's own `created` autodate rather than a
  /// field we write.
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
  /// because the repo reconciles on a timer and would otherwise churn the
  /// engine every few seconds.
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
