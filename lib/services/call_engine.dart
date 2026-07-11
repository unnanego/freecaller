import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/log.dart';
import '../data/call_repo.dart';
import '../data/models.dart';
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
  final String _myName;
  final String _myPhone;

  EnginePhase _phase = EnginePhase.idle;
  CallSession? _session;
  CallOutcome _lastOutcome = CallOutcome.none;
  String _lastPeerName = '';
  bool _accepting = false;
  bool _muted = false;

  EnginePhase get phase => _phase;
  CallSession? get session => _session;
  CallOutcome get lastOutcome => _lastOutcome;
  bool get muted => _muted;

  Future<void> toggleMute() async {
    _muted = !_muted;
    await _livekit.setMicEnabled(!_muted);
    notifyListeners();
  }

  /// Peer of the most recent session — survives teardown so the UI can
  /// announce «Аида не отвечает» after the session is gone.
  String get lastPeerName => _lastPeerName;

  StreamSubscription<CallUiEvent>? _uiEvents;
  StreamSubscription<CallDoc?>? _docWatch;
  StreamSubscription<void>? _mediaDrop;
  Timer? _ringTimer;

  Future<void> init() async {
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
          if (doc.state == CallState.ringing && doc.calleeId == _myUid) {
            _adoptIncoming(doc);
          } else if (doc.state == CallState.accepted) {
            _adoptIncoming(doc);
            await _join(doc.callId);
          } else {
            await _callUi.end(active.callId, EndReason.remote);
          }
        } catch (e) {
          log('cold-start active call ${active.callId} failed', error: e);
          try {
            await _callUi.end(active.callId, EndReason.failed);
          } catch (_) {}
        }
      }
    } catch (e) {
      log('cold-start activeCalls failed', error: e);
    }
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
    _setPhase(EnginePhase.dialing);

    try {
      await _callUi.startOutgoing(CallDisplay(
        callId: callId,
        peerName: contact.displayName,
        peerPhone: contact.phone,
        isVideo: video,
      ));
      await _calls.createRinging(
        callId: callId,
        callerId: _myUid,
        calleeId: contact.uid,
        callerName: _myName,
        callerPhone: _myPhone,
        isVideo: video,
      );
      // Join the room immediately: the caller waits alone so audio is
      // instant the moment the callee accepts.
      await _livekit.connect(callId, video: video);
      await _enableMediaWhenReady();
    } catch (e) {
      log('startCall failed', error: e);
      await _teardown(CallOutcome.failed, writeState: CallState.ended);
      return;
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
      await _calls.setState(callId, CallState.declined);
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
    try {
      if (_session?.callId != callId) {
        final doc = await _calls.getCall(callId);
        if (doc == null || doc.calleeId != _myUid) return;
        _adoptIncoming(doc);
      }
      await _calls.setState(callId, CallState.accepted);
      await _join(callId);
    } catch (e) {
      log('accept failed', error: e);
      await _teardown(CallOutcome.failed, writeState: CallState.ended);
    } finally {
      _accepting = false;
    }
  }

  Future<void> _join(String callId) async {
    // Show the call screen immediately on answer; the LiveKit connect below
    // takes ~1-2s and shouldn't leave the user staring at the ringing UI.
    _setPhase(EnginePhase.inCall);
    await _livekit.connect(callId, video: _session?.isVideo ?? false);
    await _enableMediaWhenReady();
    await _callUi.reportConnected(callId);
  }

  // ---------------------------------------------------------------- shared

  Future<void> hangUp() async {
    switch (_phase) {
      case EnginePhase.dialing:
        await _teardown(CallOutcome.none, writeState: CallState.cancelled);
      case EnginePhase.inCall:
        await _teardown(CallOutcome.ended, writeState: CallState.ended);
      case EnginePhase.incoming:
        await _teardown(CallOutcome.none, writeState: CallState.declined);
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
    if (_session?.isVideo ?? false) {
      await _livekit.setCameraEnabled(true);
    }
  }

  /// Called by the UI shell on app resume: iOS drops/refuses camera capture
  /// while backgrounded, so re-assert it whenever we're in an active video call.
  Future<void> ensureCameraOn() async {
    if ((_session?.isVideo ?? false) &&
        (_phase == EnginePhase.inCall || _phase == EnginePhase.dialing)) {
      await _livekit.setCameraEnabled(true);
    }
  }

  Future<void> toggleSpeaker() =>
      _livekit.setSpeaker(!_livekit.speakerOn.value);

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
            await _callUi.reportConnected(callId);
            _setPhase(EnginePhase.inCall);
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

  /// Single exit path. [writeState] is set when THIS side owns the
  /// transition; omitted when reacting to the other side (doc already
  /// terminal).
  Future<void> _teardown(CallOutcome outcome, {CallState? writeState}) async {
    log('engine: teardown outcome=$outcome write=$writeState (phase=$_phase)');
    final session = _session;
    _ringTimer?.cancel();
    _ringTimer = null;
    _docWatch?.cancel();
    _docWatch = null;

    if (session != null && writeState != null) {
      try {
        await _calls.setState(session.callId, writeState,
            endedBy: writeState == CallState.ended ? _myUid : null);
      } catch (e) {
        log('teardown state write failed', error: e);
      }
    }
    await _livekit.disconnect();
    if (session != null) {
      await _callUi.end(session.callId, EndReason.local);
    }
    _session = null;
    _lastOutcome = outcome;
    _muted = false;
    _setPhase(EnginePhase.idle);
  }

  void _setPhase(EnginePhase phase) {
    _phase = phase;
    notifyListeners();
  }

  String _newCallId() => const Uuid().v4();

  @override
  void dispose() {
    _uiEvents?.cancel();
    _docWatch?.cancel();
    _mediaDrop?.cancel();
    _ringTimer?.cancel();
    super.dispose();
  }
}
