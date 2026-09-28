import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/log.dart';
import '../data/call_repo.dart';
import '../data/models.dart';
import 'call_locks.dart';
import 'call_sounds.dart';
import 'call_ui/call_ui.dart';
import 'livekit_service.dart';

enum EnginePhase { idle, dialing, incoming, inCall }

/// Why the last call left the active state — surfaced to the UI so it can
/// announce the outcome («Аида не отвечает» etc.).
enum CallOutcome { none, declined, noAnswer, failed, ended }

class CallSession {
  const CallSession({
    required this.callId,
    required this.peerUid,
    required this.peerName,
    required this.peerPhone,
    required this.outgoing,
    required this.isVideo,
  });

  final String callId;
  final String peerUid;
  final String peerName;
  final String peerPhone;
  final bool outgoing;
  final bool isVideo;

  CallSession copyWith({bool? isVideo}) => CallSession(
        callId: callId,
        peerUid: peerUid,
        peerName: peerName,
        peerPhone: peerPhone,
        outgoing: outgoing,
        isVideo: isVideo ?? this.isVideo,
      );
}

/// The single call state machine both directions and both platforms flow
/// through. One call at a time; every transition is mirrored to the call
/// doc (the source of truth both sides watch).
class CallEngine extends ChangeNotifier {
  CallEngine({
    required this._calls,
    required this._livekit,
    required this._callUi,
    required this._myUid,
    required this._myName,
    required this._myPhone,
  });

  final CallRepo _calls;
  final LiveKitService _livekit;
  final CallUi _callUi;
  final String _myUid;
  String _myName;
  String _myPhone;
  final CallSounds _sounds = CallSounds();
  final CallLocks _locks = CallLocks();

  EnginePhase _phase = EnginePhase.idle;
  CallSession? _session;
  CallOutcome _lastOutcome = CallOutcome.none;
  String _lastPeerName = '';
  bool _accepting = false;
  bool _muted = false;
  bool _cameraOff = false;
  DateTime? _connectedAt;

  EnginePhase get phase => _phase;
  CallSession? get session => _session;
  CallOutcome get lastOutcome => _lastOutcome;
  bool get muted => _muted;

  /// A connected call whose media path is down and being repaired — shown and
  /// announced so silence is not the only sign. See [_onMediaInterrupted].
  bool get reconnecting => _reconnecting;
  bool _reconnecting = false;

  /// Whether the user has stopped their own camera inside a video call.
  bool get cameraOff => _cameraOff;

  /// When the CURRENT call became connected, or null if none is.
  ///
  /// The in-call timer is derived from this rather than counted by the screen.
  /// The screen's State can outlive a call: while the app is backgrounded
  /// Flutter builds no frames, so a call that ends and a new one that starts
  /// while the phone is in someone's pocket are one uninterrupted lifetime as
  /// far as the widget tree is concerned — and a counter living there carried
  /// the first call's 45 minutes straight into the second one.
  DateTime? get connectedAt => _connectedAt;

  Future<void> toggleMute() async {
    _muted = !_muted;
    await _livekit.setMicEnabled(!_muted);
    notifyListeners();
  }

  /// Stop (or resume) publishing our own camera without leaving video mode:
  /// their picture stays, ours goes dark. Deliberately not [setVideo], which
  /// drops the whole call back to voice for both sides.
  Future<void> toggleCamera() async {
    _cameraOff = !_cameraOff;
    await _livekit.setCameraEnabled(!_cameraOff);
    notifyListeners();
  }

  /// Peer of the most recent session — survives teardown so the UI can
  /// announce «Аида не отвечает» after the session is gone.
  String get lastPeerName => _lastPeerName;

  /// Follow the owner's own profile when they edit it.
  ///
  /// These two are stamped onto every outgoing call doc, which is what the
  /// callee's ring screen reads — so a name or number changed in Settings has
  /// to reach the engine, or the person you ring keeps seeing the old one until
  /// the app is restarted.
  void updateIdentity({required String name, required String phone}) {
    _myName = name;
    _myPhone = phone;
  }

  StreamSubscription<CallUiEvent>? _uiEvents;
  StreamSubscription<CallDoc?>? _docWatch;
  StreamSubscription<void>? _mediaDrop;
  Timer? _ringTimer;
  Timer? _interruptionShown;
  Timer? _interruptionFatal;

  Future<void> init() async {
    _livekit.interrupted.addListener(_onMediaInterrupted);
    _uiEvents = _callUi.events.listen(_onUiEvent);
    _mediaDrop = _livekit.onDisconnected.listen((_) {
      log('engine: livekit onDisconnected (phase=$_phase)');
      if (_phase == EnginePhase.inCall) hangUp();
    });

    // Cold start: the user may have accepted a call from the native UI
    // before the Flutter engine booted. A stale/failed leftover call must
    // never block sign-in, so every step here is best-effort.
    try {
      for (final active in await _callUi.activeCalls()) {
        try {
          final doc = await _calls.getCall(active.callId);
          final live = doc != null &&
              (doc.state == CallState.ringing || doc.state == CallState.accepted);
          if (!live) {
            await _callUi.end(active.callId, EndReason.remote);
            continue;
          }
          if (doc.state == CallState.accepted) {
            if (!active.accepted) {
              // Accepted — by another of this user's devices; this one only
              // still shows the ring. Joining would enter the room under the
              // same identity and kick the device that actually answered.
              await _callUi.end(active.callId, EndReason.remote);
              continue;
            }
            _adoptIncoming(doc);
            await _join(doc.callId);
          } else if (doc.state == CallState.ringing && doc.calleeId == _myUid) {
            if (active.accepted) {
              // Answered already — natively, before this isolate existed (see
              // CallDisplay.accepted). The accept event is gone, so finish the
              // job it would have done: write `accepted` and join. Without this
              // the call dies here in silence, with Telecom showing an active
              // call, no audio, and the caller ringing on to the timeout.
              log('cold start: completing native accept of ${doc.callId}');
              await _accept(doc.callId);
            } else {
              _adoptIncoming(doc);
            }
          } else {
            await _callUi.end(active.callId, EndReason.remote);
          }
        } catch (e) {
          log('cold-start active call ${active.callId} failed', error: e);
          if (_session?.callId == active.callId) {
            // _join had already put the engine `inCall` when it failed. Ending
            // only the native call left that standing: a call screen with a
            // running timer and no room — and with no room there is nothing for
            // the media-recovery timeout to notice, on either side.
            await _teardown(CallOutcome.failed,
                writeState: _phase == EnginePhase.inCall
                    ? CallState.ended
                    : null);
          } else {
            try {
              await _callUi.end(active.callId, EndReason.failed);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      log('cold-start activeCalls failed', error: e);
    }

    // Deliver whatever the native side raised while this engine was still
    // booting — above all an accept. _accept() looks the call up by id and
    // adopts it itself, so a replayed accept alone is enough to recover a ring
    // the plugin no longer lists.
    _callUi.replayBuffered();
    // Broadcast delivery is asynchronous, so yield before concluding that
    // nothing picked the call up; otherwise the recovery below races an accept
    // that is already in flight and re-rings a call being answered.
    await Future<void>.delayed(Duration.zero);

    await _recoverMissedRing();
  }

  /// Clear a native call left over from an earlier one before this call takes
  /// the audio. The bookkeeping in CallKitCallUi stops those being created;
  /// this clears one that got through (or predates the fix) instead of letting
  /// it hold the route for the call being placed.
  Future<void> _clearStaleNativeCalls(String keepCallId) async {
    try {
      await _callUi.endStaleCalls(keepCallId);
    } catch (e) {
      // Best-effort: never let a failed sweep stop a call from being placed.
      log('stale native call sweep failed', error: e);
    }
  }

  /// Pick up a call that is still ringing us server-side but that the native
  /// layer can no longer account for.
  ///
  /// The loop above can only adopt what the plugin still holds, and on a phone
  /// with aggressive background management that is routinely nothing: the app
  /// is killed between the push and the answer, the user taps the ring, the app
  /// cold-starts, and by the time Dart is up the plugin's active-call list is
  /// empty and the accept event has already been raised. The caller keeps
  /// ringing; the callee is looking at the home screen with no way to answer.
  /// The call record is the only thing that survived, so ask it.
  Future<void> _recoverMissedRing() async {
    if (_phase != EnginePhase.idle || _accepting) return;
    try {
      final doc = await _calls.findRingingFor(_myUid);
      if (doc == null || _phase != EnginePhase.idle || _accepting) return;
      log('cold start: recovered ringing call ${doc.callId}');
      _adoptIncoming(doc);
      // Re-raise the native ring: adopting alone would leave the user on the
      // home screen, because `incoming` has no in-app UI of its own — the
      // native ring IS the incoming UI.
      await _callUi.showIncoming(CallDisplay(
        callId: doc.callId,
        peerName: doc.callerName,
        peerPhone: doc.callerPhone,
        isVideo: doc.isVideo,
      ));
    } catch (e) {
      // Best-effort, exactly like the loop above: a phone that cannot reach the
      // server on boot must still finish signing in.
      log('cold-start ring recovery failed', error: e);
    }
  }

  /// Whether [callId] is still the call this engine is running.
  ///
  /// Every step of placing or answering a call is an await, and the call can end
  /// inside any of them — a hangup on «Соединение…», a native `ended`, the peer
  /// giving up. The teardown for that runs to completion while the method that
  /// started the call is still suspended; when it resumes it used to carry on
  /// as if nothing had happened: publish the mic, loop the ringback in phase
  /// idle with nothing left to stop it, arm a ring timer for a dead call. So
  /// each of those methods asks this after every await. A teardown still in
  /// flight counts as gone — the session is only cleared at its very end.
  bool _owns(String callId) =>
      _session?.callId == callId && _tearingDown == null;

  /// Finish off a call that ended while [startCall] was still getting it going.
  /// The teardown that ended it could only undo what existed at that moment;
  /// this undoes what was created after.
  Future<void> _abandonStart(String callId, {required bool docCreated}) async {
    log('startCall $callId: call ended while it was being placed');
    if (docCreated) {
      // The teardown's own `cancelled` write may have raced the create and
      // 404ed, which would leave the callee ringing to the sweep. A second one
      // is at worst a rejected write.
      try {
        await _calls
            .setState(callId, CallState.cancelled)
            .timeout(Config.teardownWriteTimeout);
      } catch (e) {
        log('startCall $callId: late cancel not written', error: e);
      }
    }
    await _sounds.stopRingback();
    try {
      await _callUi.end(callId, EndReason.local);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- outgoing

  Future<void> startCall(Contact contact, {required bool video}) async {
    if (_phase != EnginePhase.idle) return;
    final callId = _newCallId();
    _session = CallSession(
      callId: callId,
      peerUid: contact.uid,
      peerName: contact.displayName,
      peerPhone: contact.phone,
      outgoing: true,
      isVideo: video,
    );
    _lastPeerName = contact.displayName;
    // Set the call's default route BEFORE the screen (and its speaker button)
    // appears: connect() now honours whatever the route is at that point, so a
    // toggle pressed while "Соединение…" is up has to be able to win.
    _livekit.prepareRoute(video: video);
    _setPhase(EnginePhase.dialing);

    try {
      // Keep Wi-Fi/CPU at full performance before we connect: the caller has no
      // telecom foreground service, so on battery Wi-Fi power-save would starve
      // WebRTC ICE and the media connect below would time out.
      await _locks.acquire();
      await _clearStaleNativeCalls(callId);
      await _callUi.startOutgoing(CallDisplay(
        callId: callId,
        peerName: contact.displayName,
        peerPhone: contact.phone,
        isVideo: video,
      ));
      if (!_owns(callId)) return _abandonStart(callId, docCreated: false);
      await _calls.createRinging(
        callId: callId,
        callerId: _myUid,
        calleeId: contact.uid,
        callerName: _myName,
        callerPhone: _myPhone,
        isVideo: video,
      );
      if (!_owns(callId)) return _abandonStart(callId, docCreated: true);
      // Join the room immediately: the caller waits alone so audio is
      // instant the moment the callee accepts.
      await _livekit.connect(callId, video: video);
      if (!_owns(callId)) return _abandonStart(callId, docCreated: true);
      await _enableMediaWhenReady();
      if (!_owns(callId)) return _abandonStart(callId, docCreated: true);
    } catch (e) {
      log('startCall failed', error: e);
      // A connect overtaken by a teardown throws too (LiveKitService.connect);
      // that call is already over, and tearing down again here would hit
      // whatever call came next.
      if (!_owns(callId)) return _abandonStart(callId, docCreated: true);
      // `cancelled`, not `ended`: the doc is still `ringing` at this point and
      // the server only allows ringing -> accepted|declined|cancelled|missed
      // (pb_hooks/calls.pb.js). Writing `ended` here came back 400, which left
      // the call `ringing` on the server — so a call that failed to bring media
      // up kept the callee's phone ringing until the 45s sweep sniped it.
      // `cancelled` is also what actually happened (the caller gave up before
      // an answer), and it is the state that pushes the callee a cancel so the
      // ring stops now rather than on the timeout.
      await _teardown(CallOutcome.failed, writeState: CallState.cancelled);
      return;
    }

    // Ringback while we wait for the callee to pick up. It plays through its
    // own player, not the room, so it needs the route applied to it separately
    // — and a beat later, once the native session has settled.
    await _sounds.startRingback();
    if (!_owns(callId)) return _abandonStart(callId, docCreated: true);
    if (_livekit.speakerOn.value) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_phase == EnginePhase.dialing && _livekit.speakerOn.value) {
          _sounds.setSpeaker(true);
        }
      });
    }

    _ringTimer = Timer(Config.ringTimeout, () async {
      if (_phase == EnginePhase.dialing) {
        await _teardown(CallOutcome.noAnswer, writeState: CallState.missed);
      }
    });

    _watchDoc(callId);
  }

  // ---------------------------------------------------------------- incoming

  /// Adopts a ringing call the native UI is already showing (push arrived;
  /// CallKit/CallStyle notification is up).
  void _adoptIncoming(CallDoc doc) {
    _session = CallSession(
      callId: doc.callId,
      peerUid: doc.callerId,
      peerName: doc.callerName,
      peerPhone: doc.callerPhone,
      outgoing: false,
      isVideo: doc.isVideo,
    );
    _lastPeerName = doc.callerName;
    _setPhase(EnginePhase.incoming);
    _watchDoc(doc.callId);
  }

  /// Callee declined the native ring. A live ring can be declined before the
  /// engine ever adopts the call (the app stays idle while the native UI rings),
  /// so write `declined` by callId directly rather than requiring `incoming`
  /// phase — otherwise the caller never learns and keeps ringing.
  Future<void> _decline(String callId) async {
    if (_phase == EnginePhase.incoming && _session?.callId == callId) {
      await _teardown(CallOutcome.none, writeState: CallState.declined);
      return;
    }
    try {
      // Only a RINGING call can be declined. This path is also reached when the
      // native UI reports `ended` for a call the PEER already ended — iOS
      // surfaces a declined ring and a remote hangup as the same
      // CXEndCallAction — and `declined` is illegal from every state but
      // `ringing` (pb_hooks/calls.pb.js; note even `accepted` only allows
      // `ended`). Writing blind produced a 400 on each remote hangup: harmless
      // to the user, since the call was over either way, but a rejected write
      // on a path that believed it had succeeded.
      // Skip the write only when we POSITIVELY know the call has moved on. If
      // the read itself fails (offline is the common case here) fall through
      // and try anyway: a decline that never reaches the caller leaves them
      // ringing to the timeout, which is worse than a rejected write.
      CallDoc? doc;
      try {
        doc = await _calls.getCall(callId);
      } catch (_) {
        doc = null;
      }
      if (doc == null || doc.state == CallState.ringing) {
        await _calls.setState(callId, CallState.declined);
      }
    } catch (e) {
      log('decline write failed', error: e);
    }
    try {
      await _callUi.end(callId, EndReason.local);
    } catch (_) {}
  }

  Future<void> _accept(String callId) async {
    // The native call UI delivers 'accept' more than once. Joining the
    // LiveKit room a second time with the same identity kicks the first
    // session (DisconnectReason.duplicateIdentity), ending the call — so
    // accepting a given call is strictly one-shot.
    if (_accepting || (_session?.callId == callId && _phase == EnginePhase.inCall)) {
      return;
    }
    _accepting = true;
    // Which terminal state is even legal below depends on how far we got: the
    // server rejects ended-from-ringing, so a failure BEFORE the accept landed
    // has to be written as `declined` instead.
    var accepted = false;
    try {
      // A session for a DIFFERENT call may still be standing here. iOS suspends
      // the isolate for as long as the phone stays in a pocket, so a call that
      // ended while the app was away is only noticed on the next resume — which
      // can be this accept. Retire it before joining: LiveKitService.connect is
      // strictly one room at a time and would silently return, leaving the new
      // call with no media and the previous call's clock still running.
      if (_session != null && _session!.callId != callId) {
        log('accept $callId: retiring stale session ${_session!.callId}');
        // CallOutcome.none deliberately: the user is answering, and an
        // announcement about the previous call landing on top of that would
        // only confuse. A connected call gets `ended` written so the other side
        // (and the recents list) learns we left; anything earlier than that has
        // its own owner for the terminal state.
        //
        // The native UI is left alone: it finished with that call long ago —
        // it is ringing this one — and on iOS "end that call" is
        // CXEndCallAction on everything CallKit holds, which would hang up the
        // call being answered right here.
        //
        // A DIALING session here is the glare case: both sides rang each other
        // at once and this side is answering theirs. That outgoing call of ours
        // is still ringing on their phone, and nothing else will ever stop it —
        // writing nothing left it ringing under the live call until the 45s
        // sweep, which is the "the other call doesn't get cancelled" report.
        // An abandoned incoming ring is the same bug one phase over.
        await _teardown(
          CallOutcome.none,
          writeState: _ownedTerminalState(_phase),
          endNativeCall: false,
        );
      }
      if (_session?.callId != callId) {
        final doc = await _calls.getCall(callId);
        if (doc == null || doc.calleeId != _myUid) {
          await _endUnadoptedNativeCall(callId);
          return;
        }
        _adoptIncoming(doc);
      }
      await _calls.accept(callId);
      accepted = true;
      if (!_owns(callId)) {
        // Torn down while the accept was on the wire — and the teardown, seeing
        // phase `incoming`, wrote `declined`, which the server refused because
        // our accept had landed first. Nobody else will close this call: the
        // callee-side recovery in _teardown stands down on purpose. We know
        // this accept was ours, so close it.
        log('accept $callId: call ended while accepting');
        try {
          await _calls
              .setState(callId, CallState.ended, endedBy: _myUid)
              .timeout(Config.teardownWriteTimeout);
        } catch (e) {
          log('accept $callId: late end not written', error: e);
        }
        return;
      }
      await _join(callId);
    } catch (e) {
      log('accept failed', error: e);
      if (_owns(callId)) {
        await _teardown(CallOutcome.failed,
            writeState: accepted ? CallState.ended : CallState.declined);
      } else {
        // No session was ever adopted for this call (the lookup failed), or a
        // teardown beat us to it. _teardown ends the native call of the SESSION
        // and there is none — so the ring the user just answered stayed up as a
        // connected call with no media behind it, in silence.
        await _endUnadoptedNativeCall(callId);
      }
    } finally {
      _accepting = false;
    }
  }

  /// End a native call the engine holds no session for.
  Future<void> _endUnadoptedNativeCall(String callId) async {
    try {
      await _callUi.end(callId, EndReason.failed);
    } catch (e) {
      log('ending unadopted native call $callId failed', error: e);
    }
    await _clearStaleNativeCalls(_session?.callId ?? '');
  }

  Future<void> _join(String callId) async {
    // Show the call screen immediately on answer; the LiveKit connect below
    // takes ~1-2s and shouldn't leave the user staring at the ringing UI.
    _livekit.prepareRoute(video: _session?.isVideo ?? false);
    _setPhase(EnginePhase.inCall);
    await _locks.acquire();
    // Same reason as the outgoing side: a leftover Telecom call owns the audio
    // route, and this one is about to need it.
    await _clearStaleNativeCalls(callId);
    await _livekit.connect(callId, video: _session?.isVideo ?? false);
    if (!_owns(callId)) return;
    await _enableMediaWhenReady();
    if (!_owns(callId)) return;
    await _callUi.reportConnected(callId);
  }

  // ---------------------------------------------------------------- shared

  /// The terminal state this side owes the call doc when it walks away while in
  /// [phase]. The server's legal transitions are mirrored here and nowhere
  /// else: hangUp and the glare retirement in [_accept] both read this table,
  /// so they cannot drift into writing a state the server rejects — which would
  /// leave the peer ringing to the 45s sweep.
  static CallState? _ownedTerminalState(EnginePhase phase) => switch (phase) {
        EnginePhase.dialing => CallState.cancelled,
        EnginePhase.inCall => CallState.ended,
        EnginePhase.incoming => CallState.declined,
        EnginePhase.idle => null,
      };

  Future<void> hangUp() async {
    switch (_phase) {
      case EnginePhase.dialing:
        await _teardown(CallOutcome.none,
            writeState: _ownedTerminalState(_phase));
      case EnginePhase.inCall:
        await _teardown(CallOutcome.ended,
            writeState: _ownedTerminalState(_phase));
      case EnginePhase.incoming:
        await _teardown(CallOutcome.none,
            writeState: _ownedTerminalState(_phase));
      case EnginePhase.idle:
        break;
    }
  }

  void _onUiEvent(CallUiEvent event) {
    log('engine: ui event ${event.type} (phase=$_phase call=${event.callId})');
    final callId = event.callId;
    switch (event.type) {
      case CallUiEventType.accept:
        if (callId != null) _accept(callId);
      case CallUiEventType.decline:
        if (callId != null) _decline(callId);
      case CallUiEventType.ended:
        // Native end/decline (lock-screen hangup, CallKit red button). On iOS
        // a declined incoming ring arrives here as `ended` (a CXEndCallAction)
        // rather than `decline`; if we never adopted it (still idle), decline
        // it by callId so the caller stops ringing.
        if (_phase != EnginePhase.idle && callId == _session?.callId) {
          hangUp();
        } else if (callId != null) {
          _decline(callId);
        }
      case CallUiEventType.remoteEnded:
        // The caller cancelled and the native ring is already gone. Nothing to
        // write — `cancelled` is theirs and already on the record — and nothing
        // to do at all for a ring the engine never adopted.
        if (_phase == EnginePhase.incoming && callId == _session?.callId) {
          _teardown(CallOutcome.none);
        }
      case CallUiEventType.timeout:
        // Incoming ring timed out natively; the caller (or the sweep)
        // writes `missed` — never the callee.
        if (_phase == EnginePhase.incoming) {
          _teardown(CallOutcome.none);
        }
      case CallUiEventType.audioSessionActivated:
        // iOS: WebRTC audio must wait for CallKit to hand over the session.
        // Honor mute — this can re-fire mid-call (route changes) and must not
        // silently un-mute the user.
        _livekit.setMicEnabled(!_muted);
        // The session that the speaker choice was applied to has just been
        // replaced by this one, so apply it again — otherwise a call answered
        // (or placed) with the speaker already on comes up on the earpiece,
        // and a video call's audio does the same.
        _livekit.reapplyRoute();
      case CallUiEventType.audioSessionDeactivated:
      case CallUiEventType.voipTokenUpdated:
        break;
    }
  }

  Future<void> _enableMediaWhenReady() async {
    // Publish the mic on both platforms. On iOS the actual audio I/O is still
    // gated natively by RTCAudioSession manual-audio (AppDelegate) until
    // CallKit activates the session, so lock-screen answers stay safe — and
    // this avoids relying on the plugin's audio-session event, which errors
    // on this version and left the iOS mic unpublished.
    await _livekit.setMicEnabled(!_muted);
    // Camera is independent of the CallKit audio session. It fails silently
    // if the app is backgrounded (lock-screen answer) — ensureCameraOn()
    // retries when the app foregrounds.
    if ((_session?.isVideo ?? false) && !_cameraOff) {
      await _livekit.setCameraEnabled(true);
    }
  }

  /// Called by the UI shell on app resume: iOS drops/refuses camera capture
  /// while backgrounded, so re-assert it whenever we're in an active video call.
  ///
  /// Never against the user's wishes: a camera they switched off must stay off
  /// across a trip to the home screen.
  Future<void> ensureCameraOn() async {
    if ((_session?.isVideo ?? false) &&
        !_cameraOff &&
        (_phase == EnginePhase.inCall || _phase == EnginePhase.dialing)) {
      await _livekit.setCameraEnabled(true);
    }
  }

  Future<void> toggleSpeaker() async {
    final on = !_livekit.speakerOn.value;
    await _livekit.setSpeaker(on);
    await _sounds.setSpeaker(on); // keep the ringback on the same route
  }

  Future<void> switchCamera() => _livekit.switchCamera();

  /// Switch this call between voice and video mid-call. Publishes/stops the
  /// camera, re-routes audio, and mirrors isVideo to the call doc so the peer
  /// follows.
  Future<void> setVideo(bool video) async {
    final s = _session;
    if (s == null || _phase != EnginePhase.inCall || s.isVideo == video) return;
    await _applyVideo(video);
    try {
      await _calls.setVideo(s.callId, video);
    } catch (e) {
      log('setVideo write failed', error: e);
    }
  }

  /// Apply a voice/video mode locally: camera on/off, audio route, session+UI.
  Future<void> _applyVideo(bool video) async {
    final s = _session;
    if (s == null) return;
    _session = s.copyWith(isVideo: video);
    // Entering video mode always starts with the camera live, whoever asked
    // for it — a stale "camera off" from earlier in the call would otherwise
    // make turning video on look broken.
    if (video) _cameraOff = false;
    await _livekit.setCameraEnabled(video);
    await _livekit.setSpeaker(video);
    notifyListeners();
  }

  void _watchDoc(String callId) {
    _docWatch?.cancel();
    _docWatch = _calls.watchCall(callId).listen((doc) async {
      log('engine: doc $callId -> ${doc?.state} (phase=$_phase)');
      if (doc == null || _session?.callId != callId) return;
      switch (doc.state) {
        case CallState.ringing:
          break;
        case CallState.accepted:
          if (_phase == EnginePhase.dialing) {
            _ringTimer?.cancel();
            await _sounds.stopRingback();
            await _callUi.reportConnected(callId);
            // A hangup can land inside those two awaits; entering `inCall` after
            // it left a call screen with no session behind it.
            if (_phase != EnginePhase.dialing || !_owns(callId)) break;
            _setPhase(EnginePhase.inCall);
            // The flag is ignored while dialing; pick up an outage that began
            // there now that it counts.
            _onMediaInterrupted();
          } else if (_phase == EnginePhase.incoming && !_accepting) {
            // Accepted, and not by this device: the server rings every device
            // the callee owns, and another one of them answered. Only the
            // caller's cancel and the timeout are pushed, so this ring would
            // otherwise stay up — and block startCall — until that call ends.
            // Nothing to write; the call is live and theirs.
            await _teardown(CallOutcome.none);
          }
        case CallState.declined:
          if (_phase == EnginePhase.dialing) {
            await _teardown(CallOutcome.declined);
          }
        case CallState.cancelled:
          if (_phase == EnginePhase.incoming) {
            await _teardown(CallOutcome.none);
          }
        case CallState.missed:
          if (_phase != EnginePhase.idle) {
            await _teardown(CallOutcome.noAnswer);
          }
        case CallState.ended:
          if (_phase != EnginePhase.idle) {
            await _teardown(CallOutcome.ended);
          }
      }
      // Peer flipped voice<->video mid-call — follow their mode.
      if (_phase == EnginePhase.inCall &&
          _session != null &&
          doc.isVideo != _session!.isVideo) {
        await _applyVideo(doc.isVideo);
      }
    });
  }

  /// The media path of a connected call went down, or came back.
  ///
  /// The SDK repairs what it can on its own, but on a schedule that runs past a
  /// minute and in complete silence: both people heard nothing, saw a timer
  /// still counting, and eventually hung up and redialled. Bound it — say so
  /// after a moment, and past [Config.mediaRecoveryTimeout] end the call as
  /// failed, which plays the end tone and announces it.
  ///
  /// `ended` is written because the call WAS connected; the peer's own watch
  /// then closes their side at once instead of after their own timeout.
  void _onMediaInterrupted() {
    final down = _livekit.interrupted.value && _phase == EnginePhase.inCall;
    if (!down) {
      _clearInterruption();
      return;
    }
    if (_interruptionFatal != null) return;
    log('engine: media interrupted');
    _interruptionShown = Timer(Config.mediaInterruptionGrace, () {
      _reconnecting = true;
      notifyListeners();
    });
    _interruptionFatal = Timer(Config.mediaRecoveryTimeout, () async {
      if (_phase != EnginePhase.inCall || !_livekit.interrupted.value) return;
      log('engine: media did not recover, ending call');
      await _teardown(CallOutcome.failed, writeState: CallState.ended);
    });
  }

  void _clearInterruption() {
    _interruptionShown?.cancel();
    _interruptionShown = null;
    _interruptionFatal?.cancel();
    _interruptionFatal = null;
    if (_reconnecting) {
      _reconnecting = false;
      notifyListeners();
    }
  }

  /// Single exit path. [writeState] is set when THIS side owns the
  /// transition; omitted when reacting to the other side (doc already
  /// terminal). [endNativeCall] is cleared only when retiring a session the
  /// native layer has already moved past — see [_accept].
  ///
  /// One at a time. Everything below is an await, several callers can ask for
  /// the same call to end within a moment of each other (a double tap on hang
  /// up, the doc going `ended` while our own write is on the wire, the media
  /// timeout), and the tail of this method is global: it disconnects whatever
  /// room is up and returns the engine to idle. A second run overlapping the
  /// first doubled the writes and the end tone; a first run that finished LATE —
  /// after the peer had redialled and been answered — took the new call down
  /// with it. Later callers get the run already in flight.
  Future<void> _teardown(
    CallOutcome outcome, {
    CallState? writeState,
    bool endNativeCall = true,
  }) {
    final inFlight = _tearingDown;
    if (inFlight != null) return inFlight;
    final run = _runTeardown(outcome,
        writeState: writeState, endNativeCall: endNativeCall);
    _tearingDown = run;
    return run.whenComplete(() => _tearingDown = null);
  }

  Future<void>? _tearingDown;

  Future<void> _runTeardown(
    CallOutcome outcome, {
    CallState? writeState,
    bool endNativeCall = true,
  }) async {
    log('engine: teardown outcome=$outcome write=$writeState (phase=$_phase)');
    final session = _session;
    final wasConnected = _phase == EnginePhase.inCall;
    _ringTimer?.cancel();
    _ringTimer = null;
    _interruptionShown?.cancel();
    _interruptionShown = null;
    _interruptionFatal?.cancel();
    _interruptionFatal = null;
    _reconnecting = false;
    _docWatch?.cancel();
    _docWatch = null;
    await _sounds.stopRingback();

    if (session != null && writeState != null) {
      try {
        // Bounded: on a network that drops packets instead of refusing them the
        // request hangs until the OS gives up on the socket, and everything the
        // user can perceive — the call screen closing, the end tone — is below.
        await _calls
            .setState(session.callId, writeState,
                endedBy: writeState == CallState.ended ? _myUid : null)
            .timeout(Config.teardownWriteTimeout);
      } catch (e) {
        // The state this side owns can be stale by the time it is written: in
        // glare the peer may have accepted our outgoing call in the gap between
        // the last watch tick and this write, and `accepted -> cancelled` is
        // illegal server-side. Logging and moving on left the doc `accepted`
        // with nobody in the room — nothing sweeps that, so the peer sat alone
        // until they hung up. Re-read and close it with the legal transition.
        //
        // Only when this side was the CALLER — `cancelled` on a hangup or glare,
        // `missed` when the callee answers right at the ring timeout. The peer
        // is the only one who can accept our outgoing call, so an `accepted`
        // doc there really is ours to close. When this side was the callee
        // (`declined`), an `accepted` doc means another of this user's devices
        // took the ring — the server wakes every one of them — and writing
        // `ended` here would hang up the call they just answered.
        log('teardown state write failed', error: e);
        if (session.outgoing) {
          try {
            final doc = await _calls
                .getCall(session.callId)
                .timeout(Config.teardownWriteTimeout);
            if (doc?.state == CallState.accepted) {
              await _calls
                  .setState(session.callId, CallState.ended, endedBy: _myUid)
                  .timeout(Config.teardownWriteTimeout);
            }
          } catch (e2) {
            log('teardown state recovery failed', error: e2);
          }
        }
      }
    }
    // Clear any speaker-route override while the session is still live, so the
    // post-teardown end tone activates a clean output route. A speaker call
    // otherwise leaves the override set and the tone plays silently.
    if (wasConnected) {
      try {
        await _livekit.setSpeaker(false);
      } catch (_) {}
    }
    await _livekit.disconnect();
    await _locks.release();
    if (session != null && endNativeCall) {
      await _callUi.end(session.callId, EndReason.local);
      // …and anything else the native layer is still holding. Ending strictly
      // by id leaves a call the engine never adopted — a glare ring whose
      // cancel push never arrived — registered for good, because the sweep
      // otherwise runs only at the START of the next call. Until then the
      // system still believes the phone is in a call: on iOS that makes CallKit
      // refuse the next incoming report outright.
      //
      // Keep THIS call's id even though it was just ended: end() only REQUESTS
      // the end (a CXEndCallAction on iOS, a broadcast on Android), and the
      // native active-call list still names it until that lands. Sweeping it
      // too sent a second end whose echo nothing swallowed, and logged a
      // `staleNativeCall` diagnostic on every ordinary hangup.
      await _clearStaleNativeCalls(session.callId);
    }
    // Cue that a connected call has dropped (not for unanswered/declined rings).
    // Fire-and-forget: it self-delays for the session to settle, so awaiting it
    // would just hold the call screen open a beat longer.
    if (wasConnected) unawaited(_sounds.playEnded());
    _session = null;
    _lastOutcome = outcome;
    _muted = false;
    _cameraOff = false;
    _setPhase(EnginePhase.idle);
  }

  void _setPhase(EnginePhase phase) {
    _phase = phase;
    // Stamp the connect time once per call, on the transition into it.
    if (phase == EnginePhase.inCall) {
      _connectedAt ??= DateTime.now();
    } else if (phase != EnginePhase.dialing) {
      _connectedAt = null;
    }
    notifyListeners();
  }

  String _newCallId() => const Uuid().v4();

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    // The shell goes away with a call still up when the session is revoked
    // mid-call (refreshSession runs on every resume). LiveKitService and the
    // native call UI outlive this object, so walking away left the room open,
    // the mic live and the peer waiting. Best-effort: the write may well be
    // refused with the session gone, but the media and the native call end.
    if (_phase != EnginePhase.idle) {
      unawaited(_teardown(CallOutcome.none,
          writeState: _ownedTerminalState(_phase)));
    }
    _disposed = true;
    _uiEvents?.cancel();
    _docWatch?.cancel();
    _mediaDrop?.cancel();
    _ringTimer?.cancel();
    _interruptionShown?.cancel();
    _interruptionFatal?.cancel();
    _livekit.interrupted.removeListener(_onMediaInterrupted);
    _sounds.dispose();
    _locks.release();
    super.dispose();
  }
}
