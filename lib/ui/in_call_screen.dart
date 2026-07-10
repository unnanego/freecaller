import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:livekit_client/livekit_client.dart';

import '../services/call_engine.dart';
import '../services/livekit_service.dart';

/// Shown while dialing or in a call.
///
/// Voice call: status + a giant speaker toggle + a giant hang-up bar.
/// Video call, Google-Meet style: the active feed is full screen (remote by
/// default), the other floats in a corner — tap it to swap; plus camera
/// switch. The hang-up bar is always in the same place.
class InCallScreen extends StatefulWidget {
  const InCallScreen({super.key, required this.engine, required this.livekit});

  final CallEngine engine;
  final LiveKitService livekit;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  bool _localFullscreen = false;

  CallEngine get engine => widget.engine;
  LiveKitService get livekit => widget.livekit;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final session = engine.session;
    final name = session?.peerName ?? '';
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
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: livekit.speakerOn,
              builder: (context, speaker, _) {
                final label = speaker ? loc.speakerOff : loc.speakerOn;
                return Semantics(
                  button: true,
                  label: label,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          speaker ? const Color(0xFF1565C0) : const Color(0xFF37474F),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: engine.toggleSpeaker,
                    icon: ExcludeSemantics(
                      child: Icon(
                        speaker ? Icons.volume_up : Icons.volume_down,
                        color: Colors.white,
                        size: 44,
                      ),
                    ),
                    label: ExcludeSemantics(
                      child: Text(
                        label,
                        style: const TextStyle(fontSize: 28, color: Colors.white),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
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
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => _localFullscreen = !_localFullscreen),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: 110,
                            height: 150,
                            child: ExcludeSemantics(child: VideoTrackRenderer(track)),
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
