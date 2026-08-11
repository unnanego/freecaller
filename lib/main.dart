import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

import 'app.dart';
import 'core/log.dart';
import 'data/call_repo.dart';
import 'data/contact_discovery.dart';
import 'data/device_repo.dart';
import 'data/diagnostics_repo.dart';
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

  // CallKit owns the audio session on iOS, not LiveKit.
  //
  // This is a promise the app has always kept — AppDelegate sets
  // RTCAudioSession.useManualAudio and hands the session over in
  // provider(didActivate:) — but livekit_client 2.9 introduced an audio engine
  // that activates and deactivates AVAudioSession itself from track lifecycle,
  // and `automatic` is its default. Two owners of one session is how a call
  // answered from the lock screen ends up silent. `externalCallSystem` keeps the
  // SDK configuring category/mode as before while leaving activation to CallKit,
  // which is the arrangement that was working before the upgrade.
  //
  // Apple-only inside the SDK, and set before any room is connected. Android
  // routing is left alone: only ANSWERED calls are Telecom-managed there (an
  // outgoing call has no telecom session at all), so handing the SDK's Android
  // session management away wholesale would be wrong.
  // The mode API is @experimental upstream. Taken knowingly: the alternative is
  // letting the SDK contend with CallKit for the audio session, and a warning
  // about a future API change is the cheaper of the two problems.
  if (Platform.isIOS) {
    try {
      // ignore: experimental_member_use
      await AudioManager.instance.setAudioSessionManagementMode(
        // ignore: experimental_member_use
        AudioSessionManagementMode.externalCallSystem,
      );
    } catch (e) {
      log('setting external audio session mode failed', error: e);
    }
  }

  final pb = await createPocketBase();
  // The audio-route reports from a phone whose logs nobody can read.
  final diagnostics = DiagnosticsRepo(pb);
  final callUi = CallKitCallUi(diagnostics: diagnostics);
  final auth = AuthService(pb);

  final services = AppServices(
    auth: auth,
    users: UserRepo(pb),
    calls: CallRepo(pb),
    livekit: LiveKitService(pb, diagnostics: diagnostics),
    callUi: callUi,
    intents: Platform.isIOS ? IosIntentsBridge() : NoopIntentsBridge(),
    pushRegistrar: PushRegistrar(auth, DeviceRepo(pb), callUi),
    discovery: ContactDiscoveryRepo(pb),
  );

  runApp(FreecallerApp(services: services));
}
