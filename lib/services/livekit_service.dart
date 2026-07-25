import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:pocketbase/pocketbase.dart';

import '../core/config.dart';
import '../core/log.dart';
import 'call_locks.dart';

/// Wraps a single LiveKit room connection (the app is one-call-at-a-time).
/// Room name == callId; the server mints a token per participant. Voice
/// calls default to the earpiece, video calls to the speaker + front camera.
class LiveKitService {
  LiveKitService(this._pb, {CallLocks? locks}) : _locks = locks ?? CallLocks();

  final PocketBase _pb;

  /// The Android bridge — used here only for its native audio route.
  final CallLocks _locks;

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

  /// The audio route we WANT, as last chosen for this call — not necessarily
  /// what the OS is doing this instant.
  ///
  /// Both platforms rebuild the audio session more than once per call (at
  /// connect, and again when tracks appear), and every rebuild re-decides the
  /// route from scratch. So the choice is kept here and re-asserted at each of
  /// those moments; treating the OS as the source of truth is how a toggle
  /// pressed before the call connects silently disappears.
  final speakerOn = ValueNotifier<bool>(false);

  CameraPosition _cameraPosition = CameraPosition.front;

  bool get isConnected => _room?.connectionState == ConnectionState.connected;
  bool get hasPeer => (_room?.remoteParticipants.isNotEmpty) ?? false;

  Future<void> connect(String callId, {required bool video}) async {
    // Never open a second room — a duplicate identity would kick the first.
    if (_room != null) return;
    // The server checks we are a participant of a call that is still live
    // before it mints anything (pb_hooks/livekit.pb.js).
    final result = await _pb.send<Map<String, dynamic>>(
      Config.pbLiveKitTokenPath,
      method: 'POST',
      body: {'callId': callId},
    );
    final data = Map<String, dynamic>.from(result);
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
        // The user's choice, not the call mode: they may have hit the
        // speaker button while this was still connecting.
        defaultAudioOutputOptions: AudioOutputOptions(speakerOn: speakerOn.value),
      ),
    );
    _listener = room.createListener()
      ..on<ParticipantConnectedEvent>((_) {
        _peerJoined.add(null);
        // The peer's audio track is about to arrive and the session gets
        // reconfigured with it; put the route back afterwards.
        _reassertRoute();
      })
      ..on<TrackSubscribedEvent>((event) {
        if (event.track is VideoTrack) {
          remoteVideo.value = event.track as VideoTrack;
        } else {
          // Remote audio just arrived, which is exactly when the platform
          // re-decides the output device.
          _reassertRoute();
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
    // Connecting brings the audio session up and applies its own routing; the
    // choice above has to be re-asserted on the far side of that. The delayed
    // repeat is for Android: the device list is populated asynchronously once
    // the session starts, and a speaker that was not enumerated yet cannot be
    // selected — some OEM builds only expose it a beat later.
    await _applyRoute();
    Future.delayed(const Duration(milliseconds: 800), _reassertRoute);
    if (room.remoteParticipants.isNotEmpty) _peerJoined.add(null);
  }

  /// Push [speakerOn] onto the platform. Safe to call repeatedly — it is meant
  /// to be, since each call is a correction of whatever the audio session just
  /// decided on its own.
  Future<void> _applyRoute() async {
    if (_room == null) return;
    try {
      // First the SDK, so its own device switcher agrees with us and does not
      // undo the choice on the next device-change event…
      await Hardware.instance.setSpeakerphoneOn(speakerOn.value);
      // …then the platform API directly, which is what actually moves the audio
      // on OEM builds that ignore the SDK's deprecated path.
      final native = await _locks.setSpeaker(speakerOn.value);
      final outputs = await Hardware.instance.audioOutputs();
      log('audio route -> speaker=${speakerOn.value}'
          '${native == null ? '' : ' | native: $native'}'
          ' | outputs=[${outputs.map((d) => d.label).join(', ')}]');
    } catch (e) {
      log('applying audio route (speaker=${speakerOn.value}) failed', error: e);
    }
  }

  /// Re-apply the route after something that may have changed it.
  ///
  /// Android only, deliberately. There the output device list is built
  /// asynchronously once the audio session starts, so an early request can be
  /// dropped for a device that is not enumerated yet. iOS keeps the preference
  /// across its own reconfigurations, and re-asserting there just rebuilds the
  /// audio session for nothing — audible as a click mid-call.
  void _reassertRoute() {
    if (defaultTargetPlatform == TargetPlatform.android) _applyRoute();
  }

  /// The default route for a call of this mode: voice to the earpiece, video to
  /// the speaker. Called before connecting, so that a toggle pressed while the
  /// call is still connecting overrides it instead of being overwritten by it.
  void prepareRoute({required bool video}) => speakerOn.value = video;

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

  /// Record the choice first, then try to apply it. Order matters: before the
  /// room exists there is no audio session to route, and the request would be
  /// dropped — but the choice must still stick, so that connect() and every
  /// re-assert after it use it.
  Future<void> setSpeaker(bool enabled) async {
    speakerOn.value = enabled;
    await _applyRoute();
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
