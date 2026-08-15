import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../core/config.dart';
import 'models.dart';

/// That phone number, or that address, already belongs to another account.
class ProfileConflictException implements Exception {
  const ProfileConflictException(this.message);

  final String message;
}

/// The server refused a profile edit and said why, in words meant for the user
/// (the hooks answer in Russian).
class ProfileEditException implements Exception {
  const ProfileEditException(this.message);

  final String message;
}

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

  /// The owner may edit their own name, number and picture; `contacts`,
  /// `verified` and `email` stay admin-managed, enforced by
  /// `pb_hooks/users.pb.js`.
  Future<void> updateDisplayName(String uid, String name) async {
    await _users.update(uid, body: {'displayName': name});
  }

  /// Change the number this account is found by in other people's address
  /// books. The server normalises it to E.164 and refuses a number another
  /// account already holds.
  Future<void> updatePhone(String uid, String phone) async {
    try {
      await _users.update(uid, body: {'phone': phone});
    } on ClientException catch (e) {
      throw _profileError(e);
    }
  }

  /// Replace this account's picture. [bytes] is the already-encoded image; the
  /// server caps it at 2 MB and JPEG/PNG/WebP.
  Future<void> updateAvatar(String uid, Uint8List bytes, String filename) async {
    try {
      await _users.update(
        uid,
        files: [http.MultipartFile.fromBytes('avatar', bytes, filename: filename)],
      );
    } on ClientException catch (e) {
      throw _profileError(e);
    }
  }

  /// Drop the picture and go back to the initials tile. PocketBase clears a
  /// file field when it is sent as an empty value.
  Future<void> removeAvatar(String uid) async {
    try {
      await _users.update(uid, body: {'avatar': null});
    } on ClientException catch (e) {
      throw _profileError(e);
    }
  }

  /// Step one of moving the account to another mailbox: the server mails a code
  /// to [email]. Nothing changes until [confirmEmailChange] gets that code
  /// back, so the current address keeps working meanwhile.
  Future<void> requestEmailChange(String email) async {
    try {
      await _pb.send<Map<String, dynamic>>(
        Config.pbEmailChangeRequestPath,
        method: 'POST',
        body: {'email': email},
      );
    } on ClientException catch (e) {
      throw _profileError(e);
    }
  }

  /// Step two: hand back the code from the new mailbox. Returns the address now
  /// on the account.
  ///
  /// The route answers with a whole new session, and adopting it is not
  /// optional: changing the email rotates the record's token key server-side,
  /// so the token this request was made with is already dead by the time the
  /// response arrives. Refreshing instead of replacing it is what signed the
  /// first tester out mid-change — an auth-refresh straight after the confirm
  /// answers 401, and Settings went on showing the old address because the
  /// stored auth record was never updated either.
  Future<String> confirmEmailChange(String code) async {
    try {
      final result = await _pb.send<Map<String, dynamic>>(
        Config.pbEmailChangeConfirmPath,
        method: 'POST',
        body: {'code': code},
      );
      final token = result['token'];
      final record = result['record'];
      if (token is String && token.isNotEmpty && record is Map) {
        _pb.authStore.save(
          token,
          RecordModel.fromJson(Map<String, dynamic>.from(record)),
        );
      }
      final email = record is Map ? record['email'] : null;
      return email is String ? email : '';
    } on ClientException catch (e) {
      throw _profileError(e);
    }
  }

  /// Turns a hook's refusal into something the UI can show.
  ///
  /// The hooks answer in Russian and say exactly what is wrong ("Этот номер уже
  /// занят", "Неверный код"), which is more use to the person editing the field
  /// than anything the app could guess from a status code — so pass it through
  /// when there is one, and fall back to the caller's own wording when there
  /// isn't (a dropped connection has no message worth showing).
  Exception _profileError(ClientException e) {
    final message = e.response['message'];
    final text = message is String ? message.trim() : '';
    if (text.isEmpty) return e;
    return e.statusCode == 409
        ? ProfileConflictException(text)
        : ProfileEditException(text);
  }

  /// Where a stored avatar filename is served from.
  ///
  /// Built here rather than read off the record so that both paths agree: the
  /// roster read has the whole record, while contact discovery only gets a uid
  /// and a filename back from the match route. [thumb] picks one of the sizes
  /// the collection generates — the originals are never shown.
  static String avatarUrl(String uid, String filename, {String thumb = '300x300'}) {
    if (filename.isEmpty) return '';
    return '${Config.pbUrl}/api/files/'
        '${Config.pbUsersCollection}/$uid/$filename?thumb=$thumb';
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
      .map((record) => record == null
          ? null
          : UserProfile.fromRecord(
              record,
              avatarUrl: avatarUrl(record.id, record.get<String>('avatar', '')),
            ))
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
                avatarUrl: avatarUrl(c.id, c.get<String>('avatar', '')),
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
