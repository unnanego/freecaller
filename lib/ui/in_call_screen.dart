import 'dart:async';

import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

import '../data/contact_discovery.dart';
import '../services/call_engine.dart';
import '../services/livekit_service.dart';
import 'theme/modernist.dart';

/// Shown while dialing or in a call, in the Modernist system.
///
/// Voice: a centered avatar/name/timer block over a light ground with a control
/// tray (mute, speaker) and a compact End button. Video: the active feed fills
/// the dark area with the other feed floating bottom-right (tap to swap); the
/// tray holds mute + camera flip, End below.
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
  Timer? _timer;
  int _seconds = 0;
  StreamSubscription<int>? _proximitySub;
  bool _proximityOn = false;

  CallEngine get engine => widget.engine;
  LiveKitService get livekit => widget.livekit;

  @override
  void dispose() {
    _timer?.cancel();
    _proximitySub?.cancel();
    ProximitySensor.setProximityScreenOff(false).catchError((Object _) {});
    super.dispose();
  }

  /// Blank the screen when held to the ear during a voice call (like a normal
  /// call); keep it on for video. Android only holds the screen-off wake lock
  /// while the events stream is listened — subscribing is what arms it there.
  Future<void> _syncProximity(bool wantOn) async {
    if (wantOn == _proximityOn) return;
    _proximityOn = wantOn;
    try {
      if (wantOn) {
        await ProximitySensor.setProximityScreenOff(true);
        _proximitySub = ProximitySensor.events.listen((_) {});
      } else {
        await _proximitySub?.cancel();
        _proximitySub = null;
        await ProximitySensor.setProximityScreenOff(false);
      }
    } catch (_) {}
  }

  /// Start the mm:ss timer the first time we observe the connected state.
  void _ensureTimer() {
    if (_timer != null || engine.phase != EnginePhase.inCall) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  String get _elapsed {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    _ensureTimer();
    final loc = AppLocalizations.of(context)!;
    final session = engine.session;
    // Prefer the name from the user's own address book over the server name.
    final name = session == null
        ? ''
        : widget.names.resolve(session.peerUid, session.peerName);
    final isVideo = session?.isVideo ?? false;
    _syncProximity(!isVideo); // voice → screen-off near ear; video → keep on
    final dialing = engine.phase == EnginePhase.dialing;
    // Full spoken status for VoiceOver; the visual pieces are decoration.
    final spoken = dialing ? loc.dialing(name) : loc.inCallWith(name);
    final sub = dialing ? loc.connecting : _elapsed;

    return Scaffold(
      backgroundColor: Mod.bg,
      body: isVideo
          ? _videoCall(loc, name, sub, spoken)
          : _voiceCall(loc, name, sub, spoken),
    );
  }

  // ------------------------------------------------------------- voice call

  Widget _voiceCall(AppLocalizations loc, String name, String sub, String spoken) {
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Semantics(
                label: spoken,
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(loc.voiceCall.toUpperCase(), style: Mod.kicker()),
                      const SizedBox(height: Mod.s6),
                      InitialsTile(name: name, size: 132),
                      const SizedBox(height: Mod.s6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Mod.s6),
                        child: Text(name,
                            textAlign: TextAlign.center, style: Mod.h1()),
                      ),
                      const SizedBox(height: Mod.s3),
                      Text(sub,
                          style: Mod.name(color: Mod.neutral700)
                              .copyWith(fontSize: 18)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _tray([_muteButton(loc), _speakerButton(loc), _videoModeButton(loc)]),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- video call

  Widget _videoCall(AppLocalizations loc, String name, String sub, String spoken) {
    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            color: Mod.neutral900,
            child: SafeArea(
              bottom: false,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Active (fullscreen) feed.
                  ValueListenableBuilder<VideoTrack?>(
                    valueListenable:
                        _localFullscreen ? livekit.localVideo : livekit.remoteVideo,
                    builder: (context, track, _) => track != null
                        ? VideoTrackRenderer(track, fit: VideoViewFit.cover)
                        : const SizedBox.shrink(),
                  ),
                  // Name + timer overlay, top-left.
                  Positioned(
                    top: Mod.s4,
                    left: Mod.s6,
                    right: Mod.s6,
                    child: Semantics(
                      label: spoken,
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Mod.h2(color: const Color(0xFFF3F2F2))
                                    .copyWith(fontSize: 21)),
                            const SizedBox(height: 2),
                            Text(sub,
                                style: Mod.meta(
                                    color: const Color(0xFFF3F2F2))),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Floating corner feed — tap to swap.
                  Positioned(
                    right: Mod.s3,
                    bottom: Mod.s3,
                    child: _selfView(loc),
                  ),
                ],
              ),
            ),
          ),
        ),
        _tray([_muteButton(loc), _flipButton(loc), _voiceModeButton(loc)]),
      ],
    );
  }

  Widget _selfView(AppLocalizations loc) {
    return ValueListenableBuilder<VideoTrack?>(
      valueListenable: _localFullscreen ? livekit.remoteVideo : livekit.localVideo,
      builder: (context, track, _) => track == null
          ? const SizedBox.shrink()
          : Semantics(
              button: true,
              label: loc.swapVideo,
              child: Container(
                width: 96,
                height: 128,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFF3F2F2), width: 2),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeSemantics(
                        child: VideoTrackRenderer(track, fit: VideoViewFit.cover)),
                    // The local camera's renderer has its own tap/pinch detector
                    // (focus/zoom); an opaque overlay on top wins the swap tap.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          setState(() => _localFullscreen = !_localFullscreen),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // ---------------------------------------------------------------- controls

  /// Light control tray with a top rule: a centered row of square controls and
  /// the compact End button below.
  Widget _tray(List<Widget> controls) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration:
          BoxDecoration(border: Border(top: BorderSide(color: Mod.divider, width: 2))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s6, Mod.s6, Mod.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final (i, c) in controls.indexed) ...[
                    if (i > 0) const SizedBox(width: Mod.s8),
                    c,
                  ],
                ],
              ),
              const SizedBox(height: Mod.s6),
              _endButton(loc),
            ],
          ),
        ),
      ),
    );
  }

  Widget _muteButton(AppLocalizations loc) {
    final muted = engine.muted;
    return _TrayControl(
      label: muted ? loc.unmute : loc.mute,
      caption: loc.capMic,
      icon: muted ? Icons.mic_off : Icons.mic,
      active: muted,
      onTap: engine.toggleMute,
    );
  }

  Widget _speakerButton(AppLocalizations loc) {
    return ValueListenableBuilder<bool>(
      valueListenable: livekit.speakerOn,
      builder: (context, speaker, _) => _TrayControl(
        label: speaker ? loc.speakerOff : loc.speakerOn,
        caption: loc.capSpeaker,
        icon: speaker ? Icons.volume_up : Icons.volume_down,
        active: speaker,
        onTap: engine.toggleSpeaker,
      ),
    );
  }

  Widget _flipButton(AppLocalizations loc) {
    return _TrayControl(
      label: loc.switchCamera,
      caption: loc.capCamera,
      icon: Icons.cameraswitch,
      active: false,
      onTap: engine.switchCamera,
    );
  }

  /// Voice call → turn on video (publishes the camera; peer follows).
  Widget _videoModeButton(AppLocalizations loc) {
    return _TrayControl(
      label: loc.turnOnVideo,
      caption: loc.kindVideo,
      icon: Icons.videocam,
      active: false,
      onTap: () => engine.setVideo(true),
    );
  }

  /// Video call → drop back to voice (stops the camera; peer follows).
  Widget _voiceModeButton(AppLocalizations loc) {
    return _TrayControl(
      label: loc.turnOffVideo,
      caption: loc.kindVoice,
      icon: Icons.call,
      active: false,
      onTap: () => engine.setVideo(false),
    );
  }

  Widget _endButton(AppLocalizations loc) {
    return Semantics(
      button: true,
      label: loc.hangUp,
      child: InkWell(
        onTap: engine.hangUp,
        child: Container(
          color: Mod.accent,
          padding: const EdgeInsets.symmetric(horizontal: Mod.s8, vertical: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Transform.rotate(
                  angle: 2.356, // ~135° — the "hang up" phone
                  child: const Icon(Icons.call, color: Mod.bg, size: 24),
                ),
              ),
              const SizedBox(width: Mod.s2),
              ExcludeSemantics(child: Text(loc.endCall, style: Mod.button())),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 62×62 square control with a caption: accent-filled when active, outlined
/// when idle.
class _TrayControl extends StatelessWidget {
  const _TrayControl({
    required this.label,
    required this.caption,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final String caption;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? Mod.accent : Mod.surface,
                  border: active ? null : Border.all(color: Mod.divider, width: 2),
                ),
                child: Icon(icon, size: 28, color: active ? Mod.bg : Mod.text),
              ),
              const SizedBox(height: Mod.s2),
              SizedBox(
                width: 76,
                child: Text(caption,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mod.caption()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
