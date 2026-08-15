import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

class UserProfile {
  const UserProfile({
    required this.uid,
    required this.phone,
    required this.displayName,
    required this.contactUids,
    this.avatarUrl = '',
  });

  final String uid;
  final String phone;
  final String displayName;
  final List<String> contactUids;

  /// Where this person's picture is served from, or empty if they have none.
  /// Built by the repo, which knows the server address; the record itself only
  /// carries the stored filename.
  final String avatarUrl;

  /// `contacts` is a relation field, which the API serialises as a list of
  /// record ids.
  factory UserProfile.fromRecord(RecordModel record, {String avatarUrl = ''}) =>
      UserProfile(
        uid: record.id,
        phone: record.get<String>('phone', ''),
        displayName: record.get<String>('displayName', ''),
        contactUids: record.get<List<dynamic>>('contacts', const []).cast<String>(),
        avatarUrl: avatarUrl,
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
          other.avatarUrl == avatarUrl &&
          listEquals(other.contactUids, contactUids);

  @override
  int get hashCode =>
      Object.hash(uid, phone, displayName, avatarUrl, Object.hashAll(contactUids));
}

class Contact {
  const Contact({
    required this.uid,
    required this.displayName,
    required this.phone,
    this.avatarUrl = '',
  });

  final String uid;
  final String displayName;
  final String phone;

  /// Their picture, or empty when they have none — every place that shows one
  /// falls back to the initials tile.
  final String avatarUrl;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Contact &&
          other.uid == uid &&
          other.displayName == displayName &&
          other.phone == phone &&
          other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(uid, displayName, phone, avatarUrl);
}

/// Profile pictures by uid, for the screens that know who someone is but not
/// their record — a call in the history, a ringing peer.
///
/// Deliberately shaped like [ContactNames]: both answer "what do we know about
/// this uid", both are rebuilt whenever the roster is, and both fall back
/// silently when the answer is "nothing".
class PeerAvatars {
  const PeerAvatars(this._byUid);

  final Map<String, String> _byUid;

  static const empty = PeerAvatars({});

  /// Their picture, or empty — every caller falls back to the initials tile.
  String urlFor(String uid) => _byUid[uid] ?? '';
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
