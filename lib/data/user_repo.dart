import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../core/config.dart';
import 'models.dart';

/// The roster: profiles, contacts, and the in-app child-safety report.
///
/// Profile and credential are the same record here — PocketBase's `users` is an
/// auth collection — so there is no separate auth user to keep in step, and the
/// old `users/{uid}/private/creds` doc is gone with the login code it held.
///
/// As in [CallRepo], realtime is treated as a notification rather than a source
/// of truth: SSE replays nothing that was missed while disconnected, so every
/// event just triggers a re-read, and a slow timer converges the state even when
/// the subscription never arrives.
class UserRepo {
  UserRepo(this._pb);

  final PocketBase _pb;

  RecordService get _users => _pb.collection(Config.pbUsersCollection);

  /// The owner may edit their own display name — and only that; anything else
  /// is rejected by `pb_hooks/users.pb.js`.
  Future<void> updateDisplayName(String uid, String name) async {
    await _users.update(uid, body: {'displayName': name});
  }

  /// Files an in-app child-safety report. Kept fully in-app (no email/browser
  /// hand-off) to satisfy the store child-safety requirement. `created` is
  /// PocketBase's own autodate, so there is no timestamp to send.
  Future<void> submitSafetyReport(String uid, String message) async {
    await _pb.collection(Config.pbReportsCollection).create(body: {
      'reporterUid': uid,
      'type': 'child_safety',
      'message': message,
    });
  }

  /// The account's email address — what the user needs on another device to
  /// have a sign-in code sent to them, and what Settings shows. It comes from
  /// the locally stored auth record (PocketBase returns `email` for the record
  /// you are signed in as), so it costs no request and works offline.
  Stream<String?> watchSignInEmail() async* {
    String? email() {
      final value = _pb.authStore.record?.get<String>('email', '') ?? '';
      return value.isEmpty ? null : value;
    }

    yield email();
    yield* _pb.authStore.onChange.map((_) => email()).distinct();
  }

  /// Live view of the profile: emits the current value on listen, then on
  /// change. Bootstrap blocks on the first non-null value, so a stream that
  /// only pushed deltas would hang the app on a fresh install.
  Stream<UserProfile?> watchProfile(String uid) => _watchRecord(uid)
      .map((record) => record == null ? null : UserProfile.fromRecord(record))
      .distinct();

  /// The profile's contacts, resolved in the same read: `expand=contacts`
  /// returns the roster's records inline, so what used to be N per-contact
  /// reads is one request.
  Stream<List<Contact>> watchContacts(String uid) => _watchRecord(uid)
      .map((record) => [
            for (final c in record?.get<List<RecordModel>>('expand.contacts', const []) ??
                const <RecordModel>[])
              Contact(
                uid: c.id,
                displayName: c.get<String>('displayName', ''),
                phone: c.get<String>('phone', ''),
              ),
          ])
      .distinct(listEquals);

  /// The user record plus its expanded contacts: seeded on listen, re-read on
  /// every realtime event, and re-read periodically as the backstop.
  ///
  /// Callers map this to whichever view they need and drop unchanged values, so
  /// the timer costs one small request every couple of minutes and no rebuilds.
  Stream<RecordModel?> _watchRecord(String uid) {
    late final StreamController<RecordModel?> controller;
    UnsubscribeFunc? unsub;
    Timer? reconcileTimer;
    var closed = false;

    Future<void> read() async {
      if (closed) return;
      try {
        controller.add(await _users.getOne(uid, expand: 'contacts'));
      } on ClientException catch (e) {
        // 404 = the account is gone (deleted elsewhere); anything else is a
        // transport problem, where keeping the last known roster is right.
        if (e.statusCode == 404 && !closed) controller.add(null);
      } catch (_) {
        // Keep the last value; a later tick recovers.
      }
    }

    controller = StreamController<RecordModel?>(
      onListen: () async {
        await read();
        if (closed) return;
        try {
          unsub = await _users.subscribe(uid, (_) => read());
        } catch (_) {
          // Realtime unavailable: the timer below still converges.
        }
        reconcileTimer =
            Timer.periodic(Config.profileReconcileInterval, (_) => read());
      },
      onCancel: () async {
        closed = true;
        reconcileTimer?.cancel();
        try {
          await unsub?.call();
        } catch (_) {
          // Best-effort: the connection may already be gone.
        }
      },
    );
    return controller.stream;
  }
}
