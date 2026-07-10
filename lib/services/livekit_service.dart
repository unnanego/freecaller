import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../core/log.dart';

/// Wraps a single LiveKit room connection (the app is one-call-at-a-time).
/// Room name == callId; the server mints a token per participant. Voice
/// calls default to the earpiece, video calls to the speaker + front camera.
class LiveKitService {
  LiveKitService(this._functions);

  final FirebaseFunctions _functions;

  Room? _room;
  EventsListener<RoomEvent>? _listener;

  final _peerJoined = StreamController<void>.broadcast();
  final _disconnected = StreamController<void>.broadcast();

  /// Fires when the remote participant joins the room (call is truly live).
  Stream<void> get onPeerJoined => _peerJoined.stream;

  /// Fires when the room connection drops for any reason.
  Stream<void> get onDisconnected => _disconnected.stream;

  /// Remote participant's camera feed, for the in-call screen.
  final remoteVideo = ValueNotifier<VideoTrack?>(null);

  /// Our own camera feed (small self-view for sighted family members).
  final localVideo = ValueNotifier<VideoTrack?>(null);

  /// Current audio route, so the UI toggle reflects reality.
  final speakerOn = ValueNotifier<bool>(false);

  CameraPosition _cameraPosition = CameraPosition.front;

  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  bool get hasPeer => (_room?.remoteParticipants.isNotEmpty) ?? false;

  Future<void> connect(String callId, {required bool video}) async {
    final result = await _functions.httpsCallable('mintLiveKitToken').call({'callId': callId});
    final data = Map<String, dynamic>.from(result.data as Map);
    final token = data['token'] as String;
    final url = data['url'] as String;

    _cameraPosition = CameraPosition.front;
    final room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultAudioPublishOptions: const AudioPublishOptions(dtx: true),
        defaultCameraCaptureOptions: const CameraCaptureOptions(
          cameraPosition: CameraPosition.front,
          params: VideoParametersPresets.h540_169,
        ),
        defaultAudioOutputOptions: AudioOutputOptions(speakerOn: video),
      ),
    );
    speakerOn.value = video;
    _listener = room.createListener()
      ..on<ParticipantConnectedEvent>((_) => _peerJoined.add(null))
      ..on<TrackSubscribedEvent>((event) {
        if (event.track is VideoTrack) {
          remoteVideo.value = event.track as VideoTrack;
        }
      })
      ..on<TrackUnsubscribedEvent>((event) {
        if (event.track == remoteVideo.value) remoteVideo.value = null;
      })
      ..on<RoomDisconnectedEvent>((event) {
        log('livekit disconnected: ${event.reason}');
        _disconnected.add(null);
      });

    await room.connect(url, token);
    _room = room;
    if (room.remoteParticipants.isNotEmpty) _peerJoined.add(null);
  }

  Future<void> setMicEnabled(bool enabled) async {
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
  }

  /// Safe to call repeatedly: iOS can't capture camera while backgrounded
  /// (e.g. answered from the lock screen), so the engine retries this when
  /// the app foregrounds.
  Future<void> setCameraEnabled(bool enabled) async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    try {
      final publication = await participant.setCameraEnabled(enabled);
      localVideo.value =
          enabled ? publication?.track as VideoTrack? : null;
    } catch (e) {
      log('setCameraEnabled($enabled) failed', error: e);
    }
  }

  Future<void> switchCamera() async {
    final track = localVideo.value;
    if (track is! LocalVideoTrack) return;
    _cameraPosition = _cameraPosition == CameraPosition.front
        ? CameraPosition.back
        : CameraPosition.front;
    try {
      await track.setCameraPosition(_cameraPosition);
    } catch (e) {
      log('switchCamera failed', error: e);
    }
  }

  Future<void> setSpeaker(bool enabled) async {
    try {
      await Hardware.instance.setSpeakerphoneOn(enabled);
      speakerOn.value = enabled;
    } catch (e) {
      log('setSpeaker($enabled) failed', error: e);
    }
  }

  Future<void> disconnect() async {
    final room = _room;
    _room = null;
    remoteVideo.value = null;
    localVideo.value = null;
    await _listener?.dispose();
    _listener = null;
    await room?.disconnect();
    await room?.dispose();
  }
}
