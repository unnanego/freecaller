import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import 'data/call_repo.dart';
import 'data/models.dart';
import 'data/user_repo.dart';
import 'services/auth_service.dart';
import 'services/call_engine.dart';
import 'services/call_ui/call_ui.dart';
import 'services/intents/intents.dart';
import 'services/livekit_service.dart';
import 'services/push_registrar.dart';
import 'ui/activation_screen.dart';
import 'ui/call_type_screen.dart';
import 'ui/home_screen.dart';
import 'ui/in_call_screen.dart';

/// Composition root: everything long-lived, created once in main().
class AppServices {
  AppServices({
    required this.auth,
    required this.users,
    required this.calls,
    required this.livekit,
    required this.callUi,
    required this.intents,
    required this.pushRegistrar,
  });

  final AuthService auth;
  final UserRepo users;
  final CallRepo calls;
  final LiveKitService livekit;
  final CallUi callUi;
  final IntentsBridge intents;
  final PushRegistrar pushRegistrar;
}

class FreecallerApp extends StatelessWidget {
  const FreecallerApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          contrastLevel: 1.0,
        ),
        visualDensity: VisualDensity.comfortable,
      ),
      home: StreamBuilder(
        stream: services.auth.authState,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          final user = snapshot.data;
          if (user == null) return ActivationScreenHost(services: services);
          return SignedInShell(services: services, uid: user.uid);
        },
      ),
    );
  }
}

class ActivationScreenHost extends StatelessWidget {
  const ActivationScreenHost({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => ActivationScreen(auth: services.auth);
}

/// Signed-in world: loads the profile, owns the CallEngine, routes between
/// home and in-call, wires Siri/push/roster sync.
class SignedInShell extends StatefulWidget {
  const SignedInShell({super.key, required this.services, required this.uid});

  final AppServices services;
  final String uid;

  @override
  State<SignedInShell> createState() => _SignedInShellState();
}

class _SignedInShellState extends State<SignedInShell> with WidgetsBindingObserver {
  CallEngine? _engine;
  List<Contact> _contacts = const [];
  Contact? _missedFrom;
  Contact? _choosingCallTypeFor;
  CallOutcome _announcedOutcome = CallOutcome.none;

  StreamSubscription<List<Contact>>? _contactsSub;
  StreamSubscription<OutgoingCallRequest>? _siriSub;
  StreamSubscription<RemoteMessage>? _fcmForeground;
  StreamSubscription<List<CallDoc>>? _recentSub;

  AppServices get _s => widget.services;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // iOS can't capture camera in the background (e.g. call answered from
    // the lock screen) — re-assert it once the app is visible.
    if (state == AppLifecycleState.resumed) {
      _engine?.ensureCameraOn();
    }
  }

  Future<void> _bootstrap() async {
    final profile = await _s.users.watchProfile(widget.uid).first;
    if (profile == null || !mounted) return;

    final engine = CallEngine(
      calls: _s.calls,
      livekit: _s.livekit,
      callUi: _s.callUi,
      myUid: profile.uid,
      myName: profile.displayName,
      myPhone: profile.phone,
    );
    engine.addListener(_onEngineChanged);
    await engine.init();

    await _s.callUi.requestPermissions();
    await _s.pushRegistrar.register();

    var siriFlushed = false;
    _contactsSub = _s.users.watchContacts(widget.uid).listen((contacts) {
      setState(() => _contacts = contacts);
      // Keep Siri's vocabulary and the Intents extension snapshot current.
      _s.intents.syncContacts(contacts);
      // Flush a Siri request that arrived before Dart was listening — only
      // once contacts exist, so the uid can resolve.
      if (!siriFlushed) {
        siriFlushed = true;
        _s.intents.ready();
      }
    });

    _siriSub = _s.intents.startCallRequests.listen((request) {
      final match = _contacts.where((c) => c.uid == request.contactUid);
      if (match.isNotEmpty) {
        engine.startCall(match.first, video: request.video);
      }
    });

    // Android foreground: VoIP-style pushes only arrive via FCM here; show
    // the native ring. iOS always rings natively via PushKit.
    if (Platform.isAndroid) {
      _fcmForeground = FirebaseMessaging.onMessage.listen((message) {
        final data = message.data;
        if (data['type'] == 'incoming_call' && data['callId'] is String) {
          _s.callUi.showIncoming(CallDisplay(
            callId: data['callId'] as String,
            peerName: data['callerName'] as String? ?? '',
            peerPhone: data['callerPhone'] as String? ?? '',
            isVideo: data['video'] == 'true',
          ));
        }
      });
    }

    _recentSub = _s.calls.watchRecentIncoming(widget.uid).listen((recent) {
      final missed = recent
          .where((c) =>
              c.state == CallState.missed &&
              c.createdAt != null &&
              DateTime.now().difference(c.createdAt!) < const Duration(hours: 24))
          .toList();
      setState(() {
        _missedFrom = missed.isEmpty
            ? null
            : Contact(
                uid: missed.first.callerId,
                displayName: missed.first.callerName,
                phone: missed.first.callerPhone,
              );
      });
    });

    setState(() => _engine = engine);
  }

  void _onEngineChanged() {
    if (!mounted) return;
    setState(() {});
    final engine = _engine;
    if (engine == null) return;
    if (engine.phase == EnginePhase.idle &&
        engine.lastOutcome != CallOutcome.none &&
        engine.lastOutcome != _announcedOutcome) {
      _announcedOutcome = engine.lastOutcome;
      _announceOutcome(engine.lastOutcome);
    }
    if (engine.phase != EnginePhase.idle) {
      _announcedOutcome = CallOutcome.none;
    }
  }

  void _announceOutcome(CallOutcome outcome) {
    final loc = AppLocalizations.of(context);
    if (loc == null) return;
    final name = _engine?.lastPeerName ?? '';
    final text = switch (outcome) {
      CallOutcome.declined => loc.callDeclined(name),
      CallOutcome.noAnswer => loc.callNoAnswer(name),
      CallOutcome.failed => loc.callFailed,
      CallOutcome.ended => loc.callEnded,
      CallOutcome.none => null,
    };
    if (text == null) return;
    // Spoken by VoiceOver/TalkBack even with no visual focus change.
    SemanticsService.sendAnnouncement(View.of(context), text, TextDirection.ltr);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text, style: const TextStyle(fontSize: 24))),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _contactsSub?.cancel();
    _siriSub?.cancel();
    _fcmForeground?.cancel();
    _recentSub?.cancel();
    _engine?.removeListener(_onEngineChanged);
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    if (engine == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (engine.phase == EnginePhase.dialing || engine.phase == EnginePhase.inCall) {
      return InCallScreen(engine: engine, livekit: _s.livekit);
    }
    final choosing = _choosingCallTypeFor;
    if (choosing != null) {
      return CallTypeScreen(
        contact: choosing,
        onStart: (contact, {required video}) {
          setState(() => _choosingCallTypeFor = null);
          engine.startCall(contact, video: video);
        },
        onCancel: () => setState(() => _choosingCallTypeFor = null),
      );
    }
    return HomeScreen(
      contacts: _contacts,
      missedFrom: _missedFrom,
      onCall: (contact) => setState(() => _choosingCallTypeFor = contact),
    );
  }
}
