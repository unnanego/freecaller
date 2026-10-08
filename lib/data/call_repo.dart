import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import '../core/config.dart';
import 'models.dart';

/// The `calls` collection: call signaling, and the only thing the two devices
/// share before media is up.
///
/// One behavioural difference from the Firestore version this replaced drives
/// the whole design of [watchCall]: PocketBase realtime is SSE that **never
/// replays what you missed** while disconnected (no event log, no cursor), and
/// the server drops idle connections after ~5 minutes. The SDK silently
/// reconnects and resubscribes, so a dropped WiFi→cellular handoff mid-call
/// looks like nothing happened — except the `accepted` event that fired during
/// the gap is gone forever.
///
/// So realtime is treated as a *notification*, never as the source of truth:
/// [watchCall] seeds itself from the server on listen and re-reconciles on a
/// timer, with the subscription only there to make the common case instant.
class CallRepo {
  CallRepo(this._pb, {required this._deviceId});

  final PocketBase _pb;

  /// This install's id (AuthService.deviceId), the one its `devices` record
  /// is keyed by.
  final Future<String> Function() _deviceId;

  RecordService get _calls => _pb.collection(Config.pbCallsCollection);

  /// Creates the call in `ringing`. This write is what fans the incoming-call
  /// push out to the callee's devices, server-side (`pb_hooks/calls.pb.js`).
  Future<void> createRinging({
    required String callId,
    required String callerId,
    required String calleeId,
    required String callerName,
    required String callerPhone,
    required bool isVideo,
  }) async {
    // `createdAt` has no counterpart here: PocketBase stamps every record with
    // its own `created` autodate, which is what CallDoc.fromRecord reads.
    await _calls.create(body: {
      'id': callId,
      'callerId': callerId,
      'calleeId': calleeId,
      'callerName': callerName,
      'callerPhone': callerPhone,
      'isVideo': isVideo,
      'state': CallState.ringing.name,
      'ringExpiresAt':
          DateTime.now().toUtc().add(Config.ringTimeout).toIso8601String(),
    });
  }

  Future<void> setState(String callId, CallState state, {String? endedBy}) async {
    // Illegal transitions are rejected server-side by pb_hooks/calls.pb.js,
    // which also makes this write a compare-and-swap: of two racing accepts,
    // the second finds the call is no longer `ringing` and throws.
    //
    // Answering or declining also names this device in `answeredOn`. One
    // account can be signed in on several phones, tablets and a watch, all
    // rung at once; the server sends a cancel push to every one of them except
    // the device named here, so the rest stop ringing at once instead of on
    // their next reconcile. Only the callee writes these two states, and only
    // out of `ringing`, which is exactly when the server accepts the field.
    final now = DateTime.now().toUtc().toIso8601String();
    final answering =
        state == CallState.accepted || state == CallState.declined;
    final answeredOn = answering ? await _deviceId() : null;
    await _calls.update(callId, body: {
      'state': state.name,
      'answeredOn': ?answeredOn,
      if (state == CallState.accepted) 'acceptedAt': now,
      if (state == CallState.ended ||
          state == CallState.declined ||
          state == CallState.cancelled ||
          state == CallState.missed)
        'endedAt': now,
      'endedBy': ?endedBy,
    });
  }

  /// `ringing -> accepted`, surviving a lost response.
  ///
  /// A server rejection (another of this user's devices won the CAS, or the
  /// call is already terminal) throws as usual. A transport failure is
  /// ambiguous — the write may have landed with only the reply lost — and
  /// treating it as "not accepted" left the doc `accepted` with this device
  /// gone and the caller waiting alone, since nothing here may legally close an
  /// `accepted` call it does not believe is its own. So re-read: if the call is
  /// `accepted`, the accept is taken as ours.
  ///
  /// `answeredOn` tells the two apart when the request never arrived and
  /// another device accepted in the same instant: it names the device that
  /// won. It is empty only when the winner is a build from before the field,
  /// and then the accept is still taken as ours, as it always was.
  Future<void> accept(String callId) async {
    try {
      await setState(callId, CallState.accepted);
    } on ClientException catch (e) {
      // statusCode 0 is the SDK's "no HTTP response"; anything else is the
      // server answering, and its answer was no.
      if (e.statusCode != 0) rethrow;
      final RecordModel record;
      try {
        record = await _calls.getOne(callId);
      } on ClientException {
        throw e;
      }
      if (record.get<String>('state', '') != CallState.accepted.name) rethrow;
      final winner = record.get<String>('answeredOn', '');
      if (winner.isNotEmpty && winner != await _deviceId()) rethrow;
    }
  }

  /// Flip a live call between voice and video; the peer follows via its watch.
  Future<void> setVideo(String callId, bool video) async {
    await _calls.update(callId, body: {'isVideo': video});
  }

  Future<CallDoc?> getCall(String callId) async {
    try {
      return CallDoc.fromRecord(await _calls.getOne(callId));
    } on ClientException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// The call currently ringing [uid], straight from the server.
  ///
  /// Cold-start recovery depends on this. The native ring is the only incoming
  /// UI there is, and everything that knows about it — the plugin's active-call
  /// list, the accept event — lives in a process the OS is free to kill between
  /// the push arriving and the user answering. The call record does not, so it
  /// is the one place that still knows someone is ringing after the app comes
  /// back from nothing.
  ///
  /// Only calls still inside the ring window are returned: `ringing` is cleared
  /// by the caller's own timer or, if that never happens, by a sweep that runs
  /// on a coarser one-minute cron, so a record can read `ringing` for up to a
  /// minute after nobody is waiting on it any more.
  Future<CallDoc?> findRingingFor(String uid) async {
    // uid is the server-issued auth id, never free text.
    final page = await _calls.getList(
      page: 1,
      perPage: 1,
      filter: "calleeId = '$uid' && state = 'ringing'",
      sort: '-created',
    );
    if (page.items.isEmpty) return null;
    final doc = CallDoc.fromRecord(page.items.first);
    final created = doc.createdAt;
    if (created == null) return null;
    final age = DateTime.now().toUtc().difference(created.toUtc());
    return age < Config.ringTimeout ? doc : null;
  }

  /// Live view of one call: emits the current value on listen, then on every
  /// change, and `null` once the record is gone.
  Stream<CallDoc?> watchCall(String callId) {
    late final StreamController<CallDoc?> controller;
    UnsubscribeFunc? unsub;
    Timer? reconcileTimer;
    var closed = false;
    var emittedOnce = false;
    CallDoc? last;
    // The `updated` autodate of the newest record applied so far, and whether
    // the record has been seen to go away. See [apply].
    DateTime? lastUpdated;
    var gone = false;

    void emit(CallDoc? doc) {
      if (closed) return;
      if (emittedOnce && doc == last) return; // don't wake the engine for nothing
      emittedOnce = true;
      last = doc;
      controller.add(doc);
    }

    /// Everything that arrives — a realtime event or a reconcile read — goes
    /// through here, because the two race. A reconcile `getOne` already in
    /// flight can come back *after* a newer realtime event was applied, and
    /// [emit] only drops values equal to the last one, so the older record used
    /// to be emitted as if it were news: `isVideo` flipped back off until the
    /// next tick put it right. The server stamps `updated` on every write, so
    /// anything older than what was already applied is a late arrival, not a
    /// change, and is dropped. The same goes for a read that lands after the
    /// delete event: a record that is gone does not come back.
    void apply(RecordModel record) {
      if (closed || gone) return;
      // A state this build has never heard of. [callStateFrom] would read it
      // as `ended`, and the engine acts on `ended` by tearing the call down —
      // so a state added server-side would hang up every live call on an old
      // client. Not knowing what a record means is no reason to act on it:
      // skip it and keep the last state we did understand. (The fallback stays
      // in callStateFrom for the history list, where `ended` is a harmless
      // reading of a call that is over one way or another.)
      final raw = record.get<String>('state', '');
      if (!CallState.values.any((s) => s.name == raw)) return;

      final updated = DateTime.tryParse(record.get<String>('updated', ''));
      final newest = lastUpdated;
      if (updated != null && newest != null && updated.isBefore(newest)) return;
      if (updated != null) lastUpdated = updated;
      emit(CallDoc.fromRecord(record));
    }

    /// Ask the server what the truth is. Failures are swallowed on purpose —
    /// offline is expected mid-call, and the timer will try again shortly.
    Future<void> reconcile() async {
      if (closed) return;
      try {
        apply(await _calls.getOne(callId));
      } on ClientException catch (e) {
        // 404 = the record is gone. Anything else: keep the last known state;
        // a later tick recovers.
        if (e.statusCode == 404) emit(null);
      } catch (_) {
        // As above.
      }
    }

    Future<void> start() async {
      // 1. Nothing is pushed until something changes, so seed the current value
      //    ourselves — the engine needs state the moment it subscribes.
      await reconcile();
      if (closed) return;

      // 2. Then let realtime deliver changes instantly in the happy path.
      try {
        unsub = await _calls.subscribe(callId, (e) {
          if (e.action == 'delete') {
            gone = true;
            emit(null);
            return;
          }
          final record = e.record;
          if (record != null) apply(record);
        });
      } catch (_) {
        // Couldn't subscribe (offline / server down). Not fatal: the reconcile
        // timer below still converges on the right state.
      }

      // The listener can cancel while that subscribe is in flight. onCancel
      // then ran with `unsub` still null and no timer to stop, so nothing would
      // ever release what this function is about to keep: the subscription
      // would stay open and the timer would poll a finished call for the life
      // of the process. Undo it here instead.
      if (closed) {
        try {
          await unsub?.call();
        } catch (_) {
          // Best-effort: the connection may already be gone.
        }
        return;
      }

      // 3. The safety net for everything realtime can't promise — missed
      //    events during a drop, the 5-minute idle disconnect, a failed
      //    subscribe. Calls are short and this is our own server, so a few
      //    seconds' polling is cheap insurance.
      reconcileTimer = Timer.periodic(Config.callReconcileInterval, (_) => reconcile());
    }

    controller = StreamController<CallDoc?>(
      onListen: start,
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

  /// How often [watchRecent] re-reads the list with no event to prompt it.
  ///
  /// Slow on purpose: this is the history list and the missed-call banner, not
  /// a live call, and the realtime subscription covers the common case. It only
  /// has to bound how long the list can stay wrong after a dropped connection.
  static const _recentReconcileInterval = Duration(seconds: 60);

  /// Recent calls in BOTH directions — every call [uid] took part in, newest
  /// first. Also feeds the missed-call banner, which filters for itself.
  Stream<List<CallDoc>> watchRecent(String uid, {int limit = 10}) {
    late final StreamController<List<CallDoc>> controller;
    UnsubscribeFunc? unsub;
    Timer? reconcileTimer;
    var closed = false;
    List<CallDoc>? last;

    Future<void> refresh() async {
      if (closed) return;
      try {
        final page = await _calls.getList(
          page: 1,
          perPage: limit,
          // uid is the server-issued auth id, never free text.
          filter: "calleeId = '$uid' || callerId = '$uid'",
          sort: '-created',
        );
        if (closed) return;
        final recent = page.items.map(CallDoc.fromRecord).toList();
        // The timer below re-reads a list that has almost never changed; don't
        // rebuild the screen (or re-raise the banner) for an identical one.
        if (listEquals(recent, last)) return;
        last = recent;
        controller.add(recent);
      } catch (_) {
        // Banner is non-critical; keep whatever we last showed.
      }
    }

    controller = StreamController<List<CallDoc>>(
      onListen: () async {
        await refresh();
        if (closed) return;
        try {
          unsub = await _calls.subscribe(
            '*',
            (_) => refresh(),
            // Both directions, matching the query above — subscribing to
            // incoming only would leave a call you placed missing from the
            // list until something else refreshed it.
            filter: "calleeId = '$uid' || callerId = '$uid'",
          );
        } catch (_) {
          // Realtime unavailable: the timer below still converges.
        }
        // Cancelled while subscribing: see the same guard in [watchCall].
        if (closed) {
          try {
            await unsub?.call();
          } catch (_) {
            // Best-effort.
          }
          return;
        }
        // Same reasoning as [watchCall]: realtime never replays what was missed
        // while disconnected, so a call that came and went during a drop would
        // otherwise stay out of the list — and out of the missed-call banner —
        // until some unrelated event happened to trigger a refresh.
        reconcileTimer =
            Timer.periodic(_recentReconcileInterval, (_) => refresh());
      },
      onCancel: () async {
        closed = true;
        reconcileTimer?.cancel();
        try {
          await unsub?.call();
        } catch (_) {
          // Best-effort.
        }
      },
    );
    return controller.stream;
  }
}
