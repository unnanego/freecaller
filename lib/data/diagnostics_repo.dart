import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../core/log.dart';

/// A one-way channel for a phone to report what it just did.
///
/// It exists for exactly one situation, and should be read as narrowly as that:
/// the phone with the audio-route bugs belongs to the primary user, who is in
/// another country, and it is updated only through Play. It can never be put on
/// a cable, so `adb logcat` — where the route report otherwise goes — is
/// unreachable, and Dart's own log() is compiled out of release builds. Without
/// this, each attempted fix costs a Play release plus a phone call and comes
/// back with "still not working" and nothing else.
///
/// Android only, deliberately. The reports are about Android audio routing and
/// nothing else produces them, and keeping the iOS binary free of any upload it
/// didn't already make means the App Store privacy declarations don't change.
///
/// Best-effort to a fault: it never awaits anything the caller cares about,
/// never throws, and a server that has no `diagnostics` collection (the
/// migration not deployed, or deliberately dropped once the bug is found) simply
/// makes every call a swallowed 404. Nothing here may ever affect a call.
class DiagnosticsRepo {
  DiagnosticsRepo(this._pb);

  final PocketBase _pb;

  static const _collection = 'diagnostics';

  /// The last detail sent per call, so a repeated report says nothing twice.
  ///
  /// The route is re-asserted several times per call by design (at connect,
  /// again once the device list has settled, again whenever a track arrives), so
  /// without this a single call would post the same line five times over a
  /// network that is at that moment carrying the call.
  final _lastDetail = <String, String>{};

  /// Record one event. Fire-and-forget: call it without awaiting.
  void record(String event, {required String detail, String? callId}) {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final uid = _pb.authStore.isValid ? _pb.authStore.record?.id : null;
    if (uid == null) return;

    final key = callId ?? '';
    if (_lastDetail[key] == detail) return;
    _lastDetail[key] = detail;
    // One call's worth of keys at a time; a long-lived process must not keep
    // every call it ever made.
    if (_lastDetail.length > 8) {
      _lastDetail.remove(_lastDetail.keys.first);
    }

    _pb.collection(_collection).create(body: {
      'userUid': uid,
      'callId': ?callId,
      'platform': 'android',
      'event': event,
      'detail': detail,
    }).catchError((Object e) {
      log('diagnostics $event failed', error: e);
      return RecordModel();
    });
  }
}
