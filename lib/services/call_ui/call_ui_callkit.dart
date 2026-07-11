import 'dart:async';
import 'dart:io';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/config.dart';
import '../../core/log.dart';
import 'call_ui.dart';

/// CallUi backed by flutter_callkit_incoming — covers both iOS (CallKit)
/// and Android (CallStyle full-screen notification + ConnectionService).
class CallKitCallUi implements CallUi {
  CallKitCallUi() {
    FlutterCallkitIncoming.onEvent.listen(_onEvent, onError: (Object e) {
      log('callkit event error', error: e);
    });
  }

  final _events = StreamController<CallUiEvent>.broadcast();

  @override
  Stream<CallUiEvent> get events => _events.stream;

  void _onEvent(CallEvent? event) {
    switch (event) {
      case CallEventActionCallAccept(:final callKitParams):
        _events.add(CallUiEvent(CallUiEventType.accept, callId: callKitParams.id));
      case CallEventActionCallDecline(:final callKitParams):
        _events.add(CallUiEvent(CallUiEventType.decline, callId: callKitParams.id));
      case CallEventActionCallEnded(:final callKitParams):
        _events.add(CallUiEvent(CallUiEventType.ended, callId: callKitParams.id));
      case CallEventActionCallTimeout(:final id):
        _events.add(CallUiEvent(CallUiEventType.timeout, callId: id));
      case CallEventActionCallToggleAudioSession(:final isActive):
        _events.add(CallUiEvent(
          isActive
              ? CallUiEventType.audioSessionActivated
              : CallUiEventType.audioSessionDeactivated,
        ));
      case CallEventActionDidUpdateDevicePushTokenVoip():
        _refreshVoipToken();
      default:
        break;
    }
  }

  Future<void> _refreshVoipToken() async {
    final token = await voipToken();
    if (token != null) {
      _events.add(CallUiEvent(
        CallUiEventType.voipTokenUpdated,
        extra: {'token': token},
      ));
    }
  }

  CallKitParams _params(CallDisplay call) => CallKitParams(
        id: call.callId,
        nameCaller: call.peerName,
        appName: 'Звонилка',
        handle: call.peerPhone,
        type: call.isVideo ? 1 : 0,
        duration: Config.ringTimeout.inMilliseconds,
        android: const AndroidParams(
          isCustomNotification: false,
          isShowLogo: false,
          ringtonePath: 'system_ringtone_default',
          isShowCallID: false,
          incomingCallNotificationChannelName: 'Входящие звонки',
          missedCallNotificationChannelName: 'Пропущенные звонки',
          isShowFullLockedScreen: true,
        ),
        ios: IOSParams(
          handleType: 'generic',
          supportsVideo: call.isVideo,
          maximumCallGroups: 1,
          maximumCallsPerCallGroup: 1,
          supportsDTMF: false,
          supportsHolding: false,
          supportsGrouping: false,
          supportsUngrouping: false,
          // videoChat routes audio to the speaker, voiceChat to the earpiece.
          audioSessionMode: call.isVideo ? 'videoChat' : 'voiceChat',
          audioSessionActive: true,
        ),
      );

  // Calls registered with the native plugin. Android outgoing calls are NOT
  // registered (see startOutgoing), so later plugin calls must be skipped
  // for them.
  final _pluginCalls = <String>{};

  @override
  Future<void> showIncoming(CallDisplay call) {
    _pluginCalls.add(call.callId);
    return FlutterCallkitIncoming.showCallkitIncoming(_params(call));
  }

  @override
  Future<void> startOutgoing(CallDisplay call) {
    // Android: don't register the outgoing call with telecom/ConnectionService
    // — it competes with flutter_webrtc for audio focus, oscillating the route
    // (speaker↔earpiece) and breaking echo cancellation. The app shows its own
    // in-call UI. iOS still needs CallKit here (CXStartCallAction).
    if (Platform.isAndroid) return Future.value();
    _pluginCalls.add(call.callId);
    return FlutterCallkitIncoming.startCall(_params(call));
  }

  @override
  Future<void> reportConnected(String callId) {
    if (!_pluginCalls.contains(callId)) return Future.value();
    return FlutterCallkitIncoming.setCallConnected(callId);
  }

  @override
  Future<void> end(String callId, EndReason reason) {
    if (!_pluginCalls.remove(callId)) return Future.value();
    return FlutterCallkitIncoming.endCall(callId);
  }

  @override
  Future<List<CallDisplay>> activeCalls() async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    return [
      for (final call in calls)
        CallDisplay(
          callId: call.id,
          peerName: call.nameCaller ?? '',
          peerPhone: call.handle ?? '',
          isVideo: call.type == 1,
        ),
    ];
  }

  @override
  Future<String?> voipToken() async {
    if (!Platform.isIOS) return null;
    final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    return (token != null && token.isNotEmpty) ? token : null;
  }

  @override
  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    // RECORD_AUDIO is mandatory: the call's foreground service is of type
    // "microphone" and Android kills the app on start without it. Camera is
    // requested too so video calls don't prompt mid-call.
    await [Permission.microphone, Permission.camera].request();
    await FlutterCallkitIncoming.requestNotificationPermission({
      'title': 'Уведомления о звонках',
      'rationaleMessagePermission': 'Нужно, чтобы показывать входящие звонки',
    });
    final canFullScreen = await FlutterCallkitIncoming.canUseFullScreenIntent();
    if (!canFullScreen) {
      await FlutterCallkitIncoming.requestFullIntentPermission();
    }
  }
}
