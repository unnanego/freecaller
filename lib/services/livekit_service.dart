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
    // Never open a second room — a duplicate identity would kick the first.
    if (_room != null) return;
    final result = await _functions.httpsCallable('mintLiveKitToken').call({'callId': callId});
    final data = Map<String, dynamic>.from(result.data as Map);
    final token = data['token'] as String;
    final url = data['url'] as String;
    // Optional TURN relay advertised by the backend (coturn over TLS/443) for
    // clients whose network throttles the direct media path to the SFU — the
    // callee on such a network otherwise can't bring media up in time and the
    // call drops right after answer. The server sends short-lived credentials;
    // we hand them to the peer connection. `iceTransportPolicy` stays default
    // ('all'), so healthy clients still go direct and only fall back to relay.
    final iceServers = _parseIceServers(data['iceServers']);

    _cameraPosition = CameraPosition.front;
    final room = Room(
      roomOptions: RoomOptions(
        // Graceful degradation for constrained networks (e.g. Russian ISPs that
        // throttle the direct media flow to our foreign server — audio fits but
        // an un-adaptive 720p stream doesn't, so video used to fail outright).
        // Simulcast publishes low fallback layers so a throttled uplink keeps
        // sending 180p/360p instead of stalling on 720p, and the SFU forwards a
        // low layer to a throttled receiver; healthy networks still pull 720p.
        // adaptiveStream stays OFF: on a 1:1 fullscreen call it only risks
        // pausing the remote feed when the render view can't be measured.
        adaptiveStream: false,
        dynacast: false,
        defaultAudioPublishOptions: const AudioPublishOptions(dtx: true),
        defaultCameraCaptureOptions: const CameraCaptureOptions(
          cameraPosition: CameraPosition.front,
          params: VideoParametersPresets.h720_169,
        ),
        defaultVideoPublishOptions: const VideoPublishOptions(
          simulcast: true,
          videoSimulcastLayers: [
            VideoParametersPresets.h180_169,
            VideoParametersPresets.h360_169,
          ],
          // Under bandwidth pressure, shed both resolution and framerate rather
          // than freezing — keeps a usable low-res feed alive on a throttled link.
          degradationPreference: DegradationPreference.balanced,
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

    await room.connect(
      url,
      token,
      connectOptions: iceServers.isEmpty
          ? const ConnectOptions()
          : ConnectOptions(
              rtcConfiguration: RTCConfiguration(iceServers: iceServers),
            ),
    );
    _room = room;
    if (room.remoteParticipants.isNotEmpty) _peerJoined.add(null);
  }

  /// Parse the backend's optional `iceServers` payload into LiveKit ICE
  /// servers. Setting these replaces the server-advertised list (the SFU
  /// advertises none), so a malformed entry is skipped rather than trusted.
  List<RTCIceServer> _parseIceServers(Object? raw) {
    if (raw is! List) return const [];
    final servers = <RTCIceServer>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final m = Map<String, dynamic>.from(entry);
      final urls = (m['urls'] as List?)
          ?.map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList();
      if (urls == null || urls.isEmpty) continue;
      servers.add(RTCIceServer(
        urls: urls,
        username: m['username'] as String?,
        credential: m['credential'] as String?,
      ));
    }
    return servers;
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
