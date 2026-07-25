import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import 'app.dart';
import 'data/call_repo.dart';
import 'data/contact_discovery.dart';
import 'data/device_repo.dart';
import 'data/pb_client.dart';
import 'data/user_repo.dart';
import 'firebase_options.dart';
import 'services/auth_service.dart';
import 'services/call_ui/call_ui.dart';
import 'services/call_ui/call_ui_callkit.dart';
import 'services/intents/intents.dart';
import 'services/intents/intents_ios.dart';
import 'services/livekit_service.dart';
import 'services/push_registrar.dart';

/// Android only: an incoming-call FCM data message arriving while the app
/// is backgrounded/terminated lands here, in a fresh isolate. Show the
/// full-screen ring immediately. (iOS incoming calls never pass through
/// here — the native PushKit handler reports to CallKit directly.)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final data = message.data;
  if (data['callId'] is! String) return;
  final callId = data['callId'] as String;
  // The caller hung up before we answered — dismiss the full-screen ring.
  if (data['type'] == 'cancel_call') {
    await CallKitCallUi().dismiss(callId);
    return;
  }
  if (data['type'] != 'incoming_call') return;
  await CallKitCallUi().showIncoming(CallDisplay(
    callId: callId,
    peerName: data['callerName'] as String? ?? '',
    peerPhone: data['callerPhone'] as String? ?? '',
    isVideo: data['video'] == 'true',
  ));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase is here for ONE thing: FCM, which is how an Android phone gets
  // woken for an incoming call. Everything else — auth, the roster, call
  // signaling, room tokens — is our own PocketBase. (iOS is woken by PushKit
  // and never touches FCM.)
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (Platform.isAndroid) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  final pb = await createPocketBase();
  final callUi = CallKitCallUi();
  final auth = AuthService(pb);

  final services = AppServices(
    auth: auth,
    users: UserRepo(pb),
    calls: CallRepo(pb),
    livekit: LiveKitService(pb),
    callUi: callUi,
    intents: Platform.isIOS ? IosIntentsBridge() : NoopIntentsBridge(),
    pushRegistrar: PushRegistrar(auth, DeviceRepo(pb), callUi),
    discovery: ContactDiscoveryRepo(pb),
  );

  runApp(FreecallerApp(services: services));
}
