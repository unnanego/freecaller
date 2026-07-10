import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/config.dart';
import '../../core/log.dart';
import '../../data/models.dart';
import 'intents.dart';

/// iOS side of the Siri flow. AppDelegate receives the INStartCallIntent
/// NSUserActivity (после «Позвони Аиде через Звонилку») and invokes
/// `startCall` on this channel with the contact uid the extension resolved.
/// `syncContacts` hands the roster to native code, which writes the App
/// Group JSON snapshot (read by the Intents extension) and refreshes
/// INVocabulary so Siri recognizes the names.
class IosIntentsBridge implements IntentsBridge {
  IosIntentsBridge() {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static const _channel = MethodChannel(Config.intentsChannel);

  final _requests = StreamController<OutgoingCallRequest>.broadcast();

  @override
  Stream<OutgoingCallRequest> get startCallRequests => _requests.stream;

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'startCall':
        _addRequest(call.arguments);
      default:
        log('unknown intents method: ${call.method}');
    }
  }

  void _addRequest(dynamic arguments) {
    final args = arguments as Map?;
    final uid = args?['contactUid'] as String?;
    if (uid == null || uid.isEmpty) return;
    _requests.add(OutgoingCallRequest(
      contactUid: uid,
      video: args?['video'] == true,
    ));
  }

  @override
  Future<void> ready() async {
    try {
      final pending = await _channel.invokeMethod<Map>('ready');
      if (pending != null) _addRequest(pending);
    } on PlatformException catch (e) {
      log('intents ready failed', error: e);
    }
  }

  @override
  Future<void> syncContacts(List<Contact> contacts) async {
    try {
      await _channel.invokeMethod('syncContacts', {
        'contacts': [
          for (final c in contacts)
            {'uid': c.uid, 'displayName': c.displayName, 'phone': c.phone},
        ],
      });
    } on PlatformException catch (e) {
      log('syncContacts failed', error: e);
    }
  }
}
