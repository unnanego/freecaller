/// Platform seam for the native call UI (CallKit on iOS, CallStyle
/// full-screen notification + ConnectionService on Android). Stage 2 adds a
/// web implementation with an in-page ringing overlay; `CallEngine` depends
/// only on this interface.
library;

class CallDisplay {
  const CallDisplay({
    required this.callId,
    required this.peerName,
    required this.peerPhone,
    required this.isVideo,
  });

  final String callId;
  final String peerName;
  final String peerPhone;
  final bool isVideo;
}

enum CallUiEventType {
  accept,
  decline,
  ended,
  timeout,
  audioSessionActivated,
  audioSessionDeactivated,
  voipTokenUpdated,
}

class CallUiEvent {
  const CallUiEvent(this.type, {this.callId, this.extra});

  final CallUiEventType type;
  final String? callId;
  final Map<String, dynamic>? extra;
}

enum EndReason { local, remote, declined, missed, failed }

abstract class CallUi {
  Stream<CallUiEvent> get events;

  /// Re-delivers events the native side raised before anything subscribed to
  /// [events]. On a cold start the user can tap Answer seconds before the
  /// Flutter engine finishes booting, and that accept would otherwise land on a
  /// stream with no listener and be dropped. Call once, right after
  /// subscribing.
  void replayBuffered();

  /// Shows the native incoming-call UI. On iOS this is normally done by the
  /// native PushKit handler before Dart is even running; this method exists
  /// for the Android FCM background isolate (and web later).
  Future<void> showIncoming(CallDisplay call);

  /// Registers an outgoing call with the OS (CXStartCallAction /
  /// self-managed ConnectionService) so the system in-call UI shows.
  Future<void> startOutgoing(CallDisplay call);

  /// Marks the call answered/connected in the native UI.
  Future<void> reportConnected(String callId);

  Future<void> end(String callId, EndReason reason);

  /// Dismiss a ringing/active native call by id even when this instance never
  /// registered it (e.g. the Android FCM background isolate) — used to cancel a
  /// stale ring when the caller hangs up before we answered.
  Future<void> dismiss(String callId);

  /// Calls the OS still considers active (used on cold start to pick up an
  /// accept that happened before the Flutter engine booted).
  Future<List<CallDisplay>> activeCalls();

  /// iOS PushKit VoIP token (null on other platforms).
  Future<String?> voipToken();

  /// One-time permission prompts (Android 13+/14+): notifications and
  /// full-screen intent. No-op on iOS.
  Future<void> requestPermissions();
}
