import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import 'core/log.dart';
import 'data/call_repo.dart';
import 'data/contact_discovery.dart';
import 'data/models.dart';
import 'data/user_repo.dart';
import 'services/auth_service.dart';
import 'services/call_engine.dart';
import 'services/call_ui/call_ui.dart';
import 'services/intents/intents.dart';
import 'services/livekit_service.dart';
import 'services/push_registrar.dart';
import 'ui/activation_screen.dart';
import 'ui/in_call_screen.dart';
import 'ui/shell/main_shell.dart';
import 'ui/theme/modernist.dart';

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
    required this.discovery,
  });

  final AuthService auth;
  final UserRepo users;
  final CallRepo calls;
  final LiveKitService livekit;
  final CallUi callUi;
  final IntentsBridge intents;
  final PushRegistrar pushRegistrar;
  final ContactDiscoveryRepo discovery;
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
      theme: Mod.theme(),
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
  UserProfile? _profile;
  List<Contact> _contacts = const [];
  List<CallDoc> _recents = const [];
  ContactNames _names = ContactNames.empty;
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
      _loadNames(); // contacts may have been granted/edited while away
    }
  }

  /// Load uid -> device-book name so device names win over server names.
  Future<void> _loadNames() async {
    final map = await _s.discovery.deviceNamesByUid();
    if (mounted) setState(() => _names = ContactNames(map));
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

    // Show the home screen as soon as the engine is ready — the steps below
    // (permissions, token upload, listeners) must never block sign-in.
    if (!mounted) {
      engine.dispose();
      return;
    }
    setState(() {
      _engine = engine;
      _profile = profile;
    });

    _loadNames();
    _s.callUi.requestPermissions().catchError((Object e) => log('permissions', error: e));
    _s.pushRegistrar.register().catchError((Object e) => log('register', error: e));

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
        if (data['callId'] is! String) return;
        final callId = data['callId'] as String;
        if (data['type'] == 'cancel_call') {
          _s.callUi.dismiss(callId);
        } else if (data['type'] == 'incoming_call') {
          _s.callUi.showIncoming(CallDisplay(
            callId: callId,
            peerName: data['callerName'] as String? ?? '',
            peerPhone: data['callerPhone'] as String? ?? '',
            isVideo: data['video'] == 'true',
          ));
        }
      });
    }

    _recentSub = _s.calls.watchRecentIncoming(widget.uid).listen((recent) {
      setState(() => _recents = recent);
    }, onError: (Object e) => log('recent calls', error: e));
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
      return InCallScreen(engine: engine, livekit: _s.livekit, names: _names);
    }
    final profile = _profile;
    if (profile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return MainShell(
      profile: profile,
      recents: _recents,
      names: _names,
      discovery: _s.discovery,
      onCall: (contact, {required video}) => engine.startCall(contact, video: video),
      onSignOut: _s.auth.signOut,
    );
  }
}
