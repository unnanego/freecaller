import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/config.dart';
import 'models.dart';

/// Backend-agnostic contract for the `calls` collection.
///
/// Everything above this seam — [CallEngine], the UI — only ever sees this
/// interface, which is what keeps the PocketBase migration confined to
/// `lib/data/`. Implementations: [FirestoreCallRepo] (shipping) and
/// [PocketBaseCallRepo] (`call_repo_pb.dart`).
abstract interface class CallRepo {
  /// Creates the call in `ringing`. This write is what fans the incoming-call
  /// push out to the callee's devices, server-side.
  Future<void> createRinging({
    required String callId,
    required String callerId,
    required String calleeId,
    required String callerName,
    required String callerPhone,
    required bool isVideo,
  });

  Future<void> setState(String callId, CallState state, {String? endedBy});

  /// Flip a live call between voice and video; the peer follows via its watch.
  Future<void> setVideo(String callId, bool video);

  /// Live view of one call: emits the current value on listen, then on every
  /// change, and `null` once the record is gone.
  Stream<CallDoc?> watchCall(String callId);

  Future<CallDoc?> getCall(String callId);

  /// Recent calls where [uid] was the callee — used for the missed-call banner.
  Stream<List<CallDoc>> watchRecentIncoming(String uid, {int limit = 10});
}

class FirestoreCallRepo implements CallRepo {
  FirestoreCallRepo(this._db);

  final FirebaseFirestore _db;

  @override
  Future<void> createRinging({
    required String callId,
    required String callerId,
    required String calleeId,
    required String callerName,
    required String callerPhone,
    required bool isVideo,
  }) {
    final now = Timestamp.now();
    return _db.collection('calls').doc(callId).set({
      'callerId': callerId,
      'calleeId': calleeId,
      'callerName': callerName,
      'callerPhone': callerPhone,
      'isVideo': isVideo,
      'state': CallState.ringing.name,
      'createdAt': now,
      'ringExpiresAt': Timestamp.fromMillisecondsSinceEpoch(
        now.millisecondsSinceEpoch + Config.ringTimeout.inMilliseconds,
      ),
    });
  }

  @override
  Future<void> setState(String callId, CallState state, {String? endedBy}) {
    return _db.collection('calls').doc(callId).update({
      'state': state.name,
      if (state == CallState.accepted) 'acceptedAt': Timestamp.now(),
      if (state == CallState.ended ||
          state == CallState.declined ||
          state == CallState.cancelled ||
          state == CallState.missed)
        'endedAt': Timestamp.now(),
      'endedBy': ?endedBy,
    });
  }

  /// Flip a live call between voice and video; the peer follows via its watch.
  /// State is unchanged, so the rules' `from == to` transition allows it.
  @override
  Future<void> setVideo(String callId, bool video) =>
      _db.collection('calls').doc(callId).update({'isVideo': video});

  @override
  Stream<CallDoc?> watchCall(String callId) => _db
      .collection('calls')
      .doc(callId)
      .snapshots()
      .map((doc) => doc.exists ? CallDoc.fromDoc(doc) : null);

  @override
  Future<CallDoc?> getCall(String callId) async {
    final doc = await _db.collection('calls').doc(callId).get();
    return doc.exists ? CallDoc.fromDoc(doc) : null;
  }

  /// Recent calls where [uid] was the callee — used for the missed-call
  /// banner. Filtered client-side to avoid a composite index.
  @override
  Stream<List<CallDoc>> watchRecentIncoming(String uid, {int limit = 10}) => _db
      .collection('calls')
      .where('calleeId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((snap) => snap.docs.map(CallDoc.fromDoc).toList());
}
