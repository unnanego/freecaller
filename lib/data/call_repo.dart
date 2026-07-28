import 'dart:async';
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
  CallRepo(this._pb);

  final PocketBase _pb;

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
    final now = DateTime.now().toUtc().toIso8601String();
    await _calls.update(callId, body: {
      'state': state.name,
      if (state == CallState.accepted) 'acceptedAt': now,
      if (state == CallState.ended ||
          state == CallState.declined ||
          state == CallState.cancelled ||
          state == CallState.missed)
        'endedAt': now,
      'endedBy': ?endedBy,
    });
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

    void emit(CallDoc? doc) {
      if (closed) return;
      if (emittedOnce && doc == last) return; // don't wake the engine for nothing
      emittedOnce = true;
      last = doc;
      controller.add(doc);
    }

    /// Ask the server what the truth is. Failures are swallowed on purpose —
    /// offline is expected mid-call, and the timer will try again shortly.
    Future<void> reconcile() async {
      if (closed) return;
      try {
        emit(await getCall(callId));
      } catch (_) {
        // Keep the last known state; a later tick recovers.
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
            emit(null);
            return;
          }
          final record = e.record;
          if (record != null) emit(CallDoc.fromRecord(record));
        });
      } catch (_) {
        // Couldn't subscribe (offline / server down). Not fatal: the reconcile
        // timer below still converges on the right state.
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

  /// Recent calls where [uid] was the callee — used for the missed-call banner.
  Stream<List<CallDoc>> watchRecentIncoming(String uid, {int limit = 10}) {
    late final StreamController<List<CallDoc>> controller;
    UnsubscribeFunc? unsub;
    var closed = false;

    Future<void> refresh() async {
      if (closed) return;
      try {
        final page = await _calls.getList(
          page: 1,
          perPage: limit,
          // uid is the server-issued auth id, never free text.
          filter: "calleeId = '$uid'",
          sort: '-created',
        );
        if (!closed) {
          controller.add(page.items.map(CallDoc.fromRecord).toList());
        }
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
            filter: "calleeId = '$uid'",
          );
        } catch (_) {
          // Realtime unavailable: the list just won't live-update.
        }
      },
      onCancel: () async {
        closed = true;
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
