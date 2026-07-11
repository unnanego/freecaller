import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

import '../data/contact_discovery.dart';
import '../services/call_engine.dart';
import '../services/livekit_service.dart';

/// Shown while dialing or in a call.
///
/// Voice call: status + a giant speaker toggle + a giant hang-up bar.
/// Video call, Google-Meet style: the active feed is full screen (remote by
/// default), the other floats in a corner — tap it to swap; plus camera
/// switch. The hang-up bar is always in the same place.
class InCallScreen extends StatefulWidget {
  const InCallScreen({
    super.key,
    required this.engine,
    required this.livekit,
    required this.names,
  });

  final CallEngine engine;
  final LiveKitService livekit;
  final ContactNames names;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  bool _localFullscreen = false;

  CallEngine get engine => widget.engine;
  LiveKitService get livekit => widget.livekit;

  @override
  void initState() {
    super.initState();
    // Voice call: blank the screen when the phone is held to the ear, like a
    // normal call. Video keeps the screen on.
    if (!(engine.session?.isVideo ?? true)) {
      ProximitySensor.setProximityScreenOff(true).catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    ProximitySensor.setProximityScreenOff(false).catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final session = engine.session;
    // Prefer the name from the user's own address book over the server name.
    final name = session == null
        ? ''
        : widget.names.resolve(session.peerUid, session.peerName);
    final isVideo = session?.isVideo ?? false;
    final status = engine.phase == EnginePhase.dialing
        ? loc.dialing(name)
        : loc.inCallWith(name);

    return Scaffold(
      backgroundColor: const Color(0xFF102027),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: isVideo ? _videoArea(loc, status) : _voiceArea(loc, status),
            ),
            _hangUpBar(loc),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- voice call

  Widget _voiceArea(AppLocalizations loc, String status) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                status,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 140,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: _muteButton(loc)),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: livekit.speakerOn,
                    builder: (context, speaker, _) {
                      final label = speaker ? loc.speakerOff : loc.speakerOn;
                      return _controlButton(
                        label: label,
                        icon: speaker ? Icons.volume_up : Icons.volume_down,
                        color: speaker ? const Color(0xFF1565C0) : const Color(0xFF37474F),
                        onPressed: engine.toggleSpeaker,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _muteButton(AppLocalizations loc) {
    final muted = engine.muted;
    return _controlButton(
      label: muted ? loc.unmute : loc.mute,
      icon: muted ? Icons.mic_off : Icons.mic,
      color: muted ? const Color(0xFFC62828) : const Color(0xFF37474F),
      onPressed: engine.toggleMute,
    );
  }

  Widget _controlButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
        onPressed: onPressed,
        icon: ExcludeSemantics(child: Icon(icon, color: Colors.white, size: 40)),
        label: ExcludeSemantics(
          child: Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, color: Colors.white)),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- video call

  Widget _videoArea(AppLocalizations loc, String status) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Active (fullscreen) feed.
        ValueListenableBuilder<VideoTrack?>(
          valueListenable: _localFullscreen ? livekit.localVideo : livekit.remoteVideo,
          builder: (context, track, _) =>
              track != null ? VideoTrackRenderer(track) : const SizedBox.shrink(),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Container(
            width: double.infinity,
            color: const Color(0xAA102027),
            padding: const EdgeInsets.all(12),
            child: Text(
              status,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        // Floating corner feed — tap to make it fullscreen.
        Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ValueListenableBuilder<VideoTrack?>(
              valueListenable:
                  _localFullscreen ? livekit.remoteVideo : livekit.localVideo,
              builder: (context, track, _) => track != null
                  ? Semantics(
                      button: true,
                      label: loc.swapVideo,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 110,
                          height: 150,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ExcludeSemantics(child: VideoTrackRenderer(track)),
                              // The local camera's VideoTrackRenderer has its own
                              // tap/pinch GestureDetector (focus/zoom) that wins
                              // the tap over a wrapping one; an opaque overlay on
                              // top intercepts it first so the swap fires.
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => setState(
                                    () => _localFullscreen = !_localFullscreen),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Semantics(
              button: true,
              label: loc.switchCamera,
              child: FloatingActionButton.large(
                heroTag: null,
                backgroundColor: const Color(0xDD37474F),
                onPressed: engine.switchCamera,
                child: const ExcludeSemantics(
                  child: Icon(Icons.cameraswitch, color: Colors.white, size: 44),
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Semantics(
              button: true,
              label: engine.muted ? loc.unmute : loc.mute,
              child: FloatingActionButton.large(
                heroTag: null,
                backgroundColor:
                    engine.muted ? const Color(0xFFC62828) : const Color(0xDD37474F),
                onPressed: engine.toggleMute,
                child: ExcludeSemantics(
                  child: Icon(engine.muted ? Icons.mic_off : Icons.mic,
                      color: Colors.white, size: 44),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- hang up

  Widget _hangUpBar(AppLocalizations loc) {
    return Semantics(
      button: true,
      label: loc.hangUp,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          height: 140,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC62828),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(32),
              ),
            ),
            onPressed: engine.hangUp,
            child: ExcludeSemantics(
              child: Text(
                loc.hangUp,
                style: const TextStyle(fontSize: 38, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
