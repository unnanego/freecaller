import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:proximity_sensor/proximity_sensor.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import '../services/call_engine.dart';
import '../services/livekit_service.dart';
import 'theme/modernist.dart';

/// On-dark palette for the immersive call surface. The rest of the app is the
/// light Modernist system, but the call screen goes full-dark like the native
/// Telegram/WhatsApp call UI — reusing Archivo + the red accent so it still
/// reads as the same app.
abstract final class _Call {
  static const bgTop = Color(0xFF2C2523);
  static const bgBottom = Color(0xFF141110);
  static const onDark = Color(0xFFF5F4F3);
  static const onDarkMuted = Color(0xFFB4AFAD);
  static Color get glass => Colors.white.withValues(alpha: 0.14);
  static Color get glassBorder => Colors.white.withValues(alpha: 0.22);
}

/// Shown while dialing or in a call. Dark, immersive, native-feeling.
///
/// Voice: a large circular avatar over a warm-charcoal gradient with a faint
/// accent glow, name + timer, and a floating tray of glass controls above a big
/// round End button. Video: the active feed fills the screen with a rounded
/// self-view floating bottom-right (tap to swap); controls float over a scrim.
class InCallScreen extends StatefulWidget {
  const InCallScreen({
    super.key,
    required this.engine,
    required this.livekit,
    required this.names,
    required this.avatars,
  });

  final CallEngine engine;
  final LiveKitService livekit;
  final ContactNames names;

  /// Peers' profile pictures, for the voice screen's big avatar.
  final PeerAvatars avatars;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  bool _localFullscreen = false;
  Timer? _timer;
  StreamSubscription<int>? _proximitySub;
  bool _proximityOn = false;
  // Video chrome (name/timer + controls) auto-hides a few seconds after it
  // appears and comes back on tap, like the native call apps.
  bool _controlsVisible = true;
  bool _hideScheduled = false;
  Timer? _hideTimer;

  CallEngine get engine => widget.engine;
  LiveKitService get livekit => widget.livekit;

  @override
  void dispose() {
    _timer?.cancel();
    _hideTimer?.cancel();
    _proximitySub?.cancel();
    ProximitySensor.setProximityScreenOff(false).catchError((Object _) {});
    super.dispose();
  }

  /// Fade the video chrome out after a spell of no interaction.
  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  /// Tap anywhere on the video toggles the chrome; showing it re-arms the fade.
  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _armHide();
    } else {
      _hideTimer?.cancel();
    }
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

  /// Run a repaint tick for as long as we're connected.
  ///
  /// The tick only asks for a rebuild — the elapsed value itself comes from the
  /// engine, per call. This State is not a reliable clock: a backgrounded app
  /// builds no frames, so it can survive the end of one call and the start of
  /// the next, and a seconds counter kept here showed the second call
  /// continuing from the first one's 45 minutes.
  void _syncTimer() {
    final running = engine.phase == EnginePhase.inCall;
    if (running == (_timer != null)) return;
    if (!running) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String get _elapsed {
    final since = engine.connectedAt;
    final elapsed = since == null ? 0 : DateTime.now().difference(since).inSeconds;
    final seconds = elapsed < 0 ? 0 : elapsed;
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    _syncTimer();
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

    // Voice keeps its controls always on; leaving video resets the auto-hide.
    if (!isVideo) {
      _controlsVisible = true;
      _hideScheduled = false;
      _hideTimer?.cancel();
      _hideTimer = null;
    }

    return Scaffold(
      backgroundColor: _Call.bgBottom,
      body: isVideo
          ? _videoCall(loc, name, sub, spoken)
          : _voiceCall(loc, name, sub, spoken),
    );
  }

  // ------------------------------------------------------------- voice call

  Widget _voiceCall(AppLocalizations loc, String name, String sub, String spoken) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Warm-charcoal vertical gradient ground.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_Call.bgTop, _Call.bgBottom],
            ),
          ),
        ),
        // Faint accent glow behind the avatar.
        Align(
          alignment: const Alignment(0, -0.55),
          child: Container(
            width: 360,
            height: 360,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Mod.accent.withValues(alpha: 0.22),
                  Mod.accent.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
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
                          _Avatar(
                            name: name,
                            size: 140,
                            imageUrl: widget.avatars
                                .urlFor(engine.session?.peerUid ?? ''),
                          ),
                          const SizedBox(height: Mod.s6),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: Mod.s6),
                            child: Text(
                              name,
                              textAlign: TextAlign.center,
                              style: Mod.h1(color: _Call.onDark),
                            ),
                          ),
                          const SizedBox(height: Mod.s3),
                          Text(
                            sub,
                            style: Mod.name(color: _Call.onDarkMuted)
                                .copyWith(fontSize: 18, fontWeight: FontWeight.w400),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _tray([
                _muteButton(loc),
                _speakerButton(loc),
                // Mode switch only works once connected — hide it while ringing.
                if (engine.phase == EnginePhase.inCall) _videoModeButton(loc),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- video call

  Widget _videoCall(AppLocalizations loc, String name, String sub, String spoken) {
    // Once connected, prime the one-shot auto-hide so the chrome fades away.
    if (engine.phase == EnginePhase.inCall &&
        _controlsVisible &&
        !_hideScheduled) {
      _hideScheduled = true;
      _armHide();
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Active (fullscreen) feed.
          ValueListenableBuilder<VideoTrack?>(
            valueListenable:
                _localFullscreen ? livekit.localVideo : livekit.remoteVideo,
            builder: (context, track, _) => track != null
                ? VideoTrackRenderer(track, fit: VideoViewFit.cover)
                : const ColoredBox(color: _Call.bgBottom),
          ),
          // Name/timer + controls fade together; the feed and self-view stay.
          AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Top scrim so the name/timer stay legible over any feed.
                  const _Scrim(alignment: Alignment.topCenter, height: 160),
                  // Bottom scrim behind the controls.
                  const _Scrim(alignment: Alignment.bottomCenter, height: 260),
                  // Name + timer top-left, own-camera switch top-right.
                  SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s6, 0),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Semantics(
                                label: spoken,
                                child: ExcludeSemantics(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Mod.h2(color: _Call.onDark)
                                            .copyWith(fontSize: 24),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(sub,
                                          style:
                                              Mod.meta(color: _Call.onDarkMuted)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: Mod.s3),
                            _cameraToggle(loc),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Controls floating over the bottom scrim.
                  SafeArea(
                    top: false,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _tray([
                        _muteButton(loc),
                        _flipButton(loc),
                        // Mode switch only works once connected.
                        if (engine.phase == EnginePhase.inCall)
                          _voiceModeButton(loc),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Floating rounded self-view — always visible, tap to swap. It rides
          // above the control tray when the chrome is showing and drops toward
          // the corner once it fades, like the native call apps.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomRight,
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(
                    right: Mod.s4, bottom: _controlsVisible ? 240 : Mod.s4),
                child: _selfView(loc),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selfView(AppLocalizations loc) {
    return ValueListenableBuilder<VideoTrack?>(
      valueListenable: _localFullscreen ? livekit.remoteVideo : livekit.localVideo,
      builder: (context, track, _) => Semantics(
        button: true,
        label: loc.swapVideo,
        child: Container(
          width: 104,
          height: 150,
          decoration: BoxDecoration(
            color: _Call.bgTop,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _Call.glassBorder, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Show the feed, or a camera-off placeholder so the tile never
                // just disappears (e.g. the peer has no video yet).
                if (track != null)
                  ExcludeSemantics(
                    child: VideoTrackRenderer(track, fit: VideoViewFit.cover),
                  )
                else
                  const Center(
                    child: Icon(Icons.videocam_off,
                        color: _Call.onDarkMuted, size: 28),
                  ),
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
      ),
    );
  }

  // ---------------------------------------------------------------- controls

  /// A centered row of glass controls with the big round End button below.
  Widget _tray(List<Widget> controls) {
    final loc = AppLocalizations.of(context)!;
    return Padding(
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
    );
  }

  Widget _muteButton(AppLocalizations loc) {
    final muted = engine.muted;
    return _RoundControl(
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
      builder: (context, speaker, _) => _RoundControl(
        label: speaker ? loc.speakerOff : loc.speakerOn,
        caption: loc.capSpeaker,
        icon: speaker ? Icons.volume_up : Icons.volume_down,
        active: speaker,
        onTap: engine.toggleSpeaker,
      ),
    );
  }

  /// Stop or resume our own camera, mid-video-call. Lives in the top-right
  /// corner rather than the tray: a fourth round control does not fit one row
  /// on a phone, and this belongs with the picture rather than with the
  /// call-wide controls — it changes only what we send, not the call's mode.
  Widget _cameraToggle(AppLocalizations loc) {
    final off = engine.cameraOff;
    return Semantics(
      button: true,
      label: off ? loc.cameraOn : loc.cameraOff,
      child: InkWell(
        onTap: engine.toggleCamera,
        customBorder: const CircleBorder(),
        child: ExcludeSemantics(
          child: ClipOval(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: off ? Mod.accent : _Call.glass,
                  border: Border.all(
                    color: off ? Mod.accent : _Call.glassBorder,
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  off ? Icons.videocam_off : Icons.videocam,
                  size: 24,
                  color: _Call.onDark,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _flipButton(AppLocalizations loc) {
    return _RoundControl(
      label: loc.switchCamera,
      caption: loc.capCamera,
      icon: Icons.cameraswitch,
      active: false,
      onTap: engine.switchCamera,
    );
  }

  /// Voice call → turn on video (publishes the camera; peer follows).
  Widget _videoModeButton(AppLocalizations loc) {
    return _RoundControl(
      label: loc.turnOnVideo,
      caption: loc.kindVideo,
      icon: Icons.videocam,
      active: false,
      onTap: () => engine.setVideo(true),
    );
  }

  /// Video call → drop back to voice (stops the camera; peer follows).
  Widget _voiceModeButton(AppLocalizations loc) {
    return _RoundControl(
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
        customBorder: const CircleBorder(),
        child: ExcludeSemantics(
          child: Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Mod.accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Mod.accent.withValues(alpha: 0.45),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Transform.rotate(
              angle: 2.356, // ~135° — the "hang up" phone
              child: const Icon(Icons.call, color: Colors.white, size: 30),
            ),
          ),
        ),
      ),
    );
  }
}

/// A circular avatar for the dark call surface: the peer's picture if we have
/// one, their initials otherwise — and their initials again while it loads or
/// if it fails, since a voice call must not sit behind a blank circle.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.size, this.imageUrl = ''});

  final String name;
  final double size;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final initials = Text(
      initialsOf(name),
      style: Mod.tileInitials(size * 0.34, color: _Call.onDark),
    );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.08),
        border: Border.all(color: _Call.glassBorder, width: 2),
      ),
      child: imageUrl.isEmpty
          ? initials
          : ClipOval(
              child: Image.network(
                imageUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : initials,
                errorBuilder: (_, _, _) => initials,
              ),
            ),
    );
  }
}

/// A top- or bottom-anchored gradient scrim for legibility over video.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.alignment, required this.height});

  final Alignment alignment;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fromTop = alignment == Alignment.topCenter;
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          height: height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
              end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: 0.55),
                Colors.black.withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round frosted-glass control with a small caption: accent-filled when
/// active, translucent glass when idle.
class _RoundControl extends StatelessWidget {
  const _RoundControl({
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
        customBorder: const CircleBorder(),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipOval(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active ? Mod.accent : _Call.glass,
                      border: Border.all(
                        color: active ? Mod.accent : _Call.glassBorder,
                        width: 1.5,
                      ),
                    ),
                    child: Icon(icon, size: 26, color: _Call.onDark),
                  ),
                ),
              ),
              const SizedBox(height: Mod.s2),
              SizedBox(
                width: 80,
                child: Text(
                  caption,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Mod.caption(color: _Call.onDarkMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
