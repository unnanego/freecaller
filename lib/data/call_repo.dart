import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/config.dart';
import 'models.dart';

class CallRepo {
  CallRepo(this._db);

  final FirebaseFirestore _db;

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

  Stream<CallDoc?> watchCall(String callId) => _db
      .collection('calls')
      .doc(callId)
      .snapshots()
      .map((doc) => doc.exists ? CallDoc.fromDoc(doc) : null);

  Future<CallDoc?> getCall(String callId) async {
    final doc = await _db.collection('calls').doc(callId).get();
    return doc.exists ? CallDoc.fromDoc(doc) : null;
  }

  /// Recent calls where [uid] was the callee — used for the missed-call
  /// banner. Filtered client-side to avoid a composite index.
  Stream<List<CallDoc>> watchRecentIncoming(String uid, {int limit = 10}) => _db
      .collection('calls')
      .where('calleeId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((snap) => snap.docs.map(CallDoc.fromDoc).toList());
}
