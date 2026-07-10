import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/config.dart';
import 'data/call_repo.dart';
import 'data/device_repo.dart';
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
  if (data['type'] != 'incoming_call' || data['callId'] is! String) return;
  await CallKitCallUi().showIncoming(CallDisplay(
    callId: data['callId'] as String,
    peerName: data['callerName'] as String? ?? '',
    peerPhone: data['callerPhone'] as String? ?? '',
    isVideo: data['video'] == 'true',
  ));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (Platform.isAndroid) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  final firestore = FirebaseFirestore.instance;
  final functions = FirebaseFunctions.instanceFor(region: Config.functionsRegion);
  final callUi = CallKitCallUi();
  final auth = AuthService(FirebaseAuth.instance, functions);

  final services = AppServices(
    auth: auth,
    users: UserRepo(firestore),
    calls: CallRepo(firestore),
    livekit: LiveKitService(functions),
    callUi: callUi,
    intents: Platform.isIOS ? IosIntentsBridge() : NoopIntentsBridge(),
    pushRegistrar: PushRegistrar(auth, DeviceRepo(firestore), callUi),
  );

  runApp(FreecallerApp(services: services));
}
