import 'dart:async';
import 'dart:io';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

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

  @override
  Future<void> showIncoming(CallDisplay call) =>
      FlutterCallkitIncoming.showCallkitIncoming(_params(call));

  @override
  Future<void> startOutgoing(CallDisplay call) =>
      FlutterCallkitIncoming.startCall(_params(call));

  @override
  Future<void> reportConnected(String callId) =>
      FlutterCallkitIncoming.setCallConnected(callId);

  @override
  Future<void> end(String callId, EndReason reason) =>
      FlutterCallkitIncoming.endCall(callId);

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
