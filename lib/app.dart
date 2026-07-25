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
          final uid = snapshot.data;
          if (uid == null) return ActivationScreenHost(services: services);
          return SignedInShell(services: services, uid: uid);
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
  /// Roster relation: who the admin/invites linked this account to.
  List<Contact> _contacts = const [];

  /// Address-book discovery: who this phone has saved AND is on the app.
  List<Contact> _discovered = const [];
  List<CallDoc> _recents = const [];
  ContactNames _names = ContactNames.empty;
  String? _signInEmail;
  bool _bootstrapFailed = false;
  CallOutcome _announcedOutcome = CallOutcome.none;

  StreamSubscription<UserProfile?>? _profileBootSub;
  Timer? _bootTimeout;
  StreamSubscription<String?>? _signInEmailSub;
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
      _s.auth.refreshSession(); // push the session expiry forward
    }
  }

  /// Read the address book once and derive both things that depend on it: the
  /// uid -> saved-name map (device names beat server names everywhere a person
  /// is shown) and the people discovery says are on the app.
  Future<void> _loadNames() async {
    final discovered = await _s.discovery.loadDeviceContacts();
    if (!mounted) return;
    if (discovered == null) {
      // No consent or no permission: nothing was read, and nothing was sent.
      _syncSiriContacts();
      return;
    }
    final blocked = await _s.discovery.blockedIds();
    if (!mounted) return;
    setState(() {
      _names = ContactNames({
        for (final c in discovered)
          if (c.onApp) c.uid!: c.name,
      });
      // The access sheet decides who this user is willing to see — and
      // therefore who Siri may place a call to.
      _discovered = [
        for (final c in discovered)
          if (c.onApp && !blocked.contains(c.deviceId)) c.toContact(),
      ];
    });
    _syncSiriContacts(); // re-teach Siri with the device names once we have them
  }

  /// Hand everyone callable to Siri/the Intents extension, under the names they
  /// are saved as in the device address book, so «Позвони Mom» resolves.
  ///
  /// Both sources, deliberately. The roster relation covers people who were
  /// invited or linked by the admin — including anyone not in this phone's
  /// address book. Discovery covers everyone whose number IS in the address
  /// book and who turned out to be on the app, linked or not. Anyone the
  /// Contacts tab lets you tap must also be reachable by voice; using only the
  /// roster left discovered contacts tappable but unspeakable, which is not a
  /// distinction any user could guess at.
  void _syncSiriContacts() {
    final byUid = <String, Contact>{};
    for (final c in [..._contacts, ..._discovered]) {
      byUid[c.uid] = Contact(
        uid: c.uid,
        displayName: _names.resolve(c.uid, c.displayName),
        phone: c.phone,
      );
    }
    _s.intents.syncContacts(byUid.values.toList());
  }

  void _bootstrap() {
    _bootstrapFailed = false;
    _bootTimeout?.cancel();
    _profileBootSub?.cancel();
    // Re-issue the session token on every launch. Backends with a hard token
    // ceiling (PocketBase: 3 years) only keep a device signed in forever if the
    // client keeps pushing the expiry out; being silently logged out is the
    // worst failure this app has. Best-effort, never blocks bootstrap.
    _s.auth.refreshSession();
    // This first profile read hits the server — nothing is cached on a fresh
    // install — and a reviewer's VPN can throttle it even though sign-in got
    // through (that was the App Store 2.1 "loads indefinitely" cause). So never
    // hang on it: show a retry after a timeout, but KEEP listening so a slow
    // connection still finishes bootstrap on its own, without needing another
    // tap.
    _bootTimeout = Timer(const Duration(seconds: 15), () {
      if (mounted && _engine == null) setState(() => _bootstrapFailed = true);
    });
    _profileBootSub = _s.users.watchProfile(widget.uid).listen(
      (profile) {
        if (profile == null || _engine != null) return;
        _bootTimeout?.cancel();
        _profileBootSub?.cancel();
        _profileBootSub = null;
        _completeBootstrap(profile);
      },
      onError: (Object e) => log('bootstrap: profile stream error', error: e),
    );
  }

  Future<void> _completeBootstrap(UserProfile profile) async {
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
      _bootstrapFailed = false; // clear the retry screen if it was showing
    });

    _loadNames();
    // Surface the address a sign-in code gets mailed to, for Settings.
    _signInEmailSub = _s.users.watchSignInEmail().listen(
      (email) { if (mounted) setState(() => _signInEmail = email); },
      onError: (Object e) => log('sign-in email', error: e),
    );
    _s.callUi.requestPermissions().catchError((Object e) => log('permissions', error: e));
    _s.pushRegistrar.register().catchError((Object e) => log('register', error: e));

    var siriFlushed = false;
    _contactsSub = _s.users.watchContacts(widget.uid).listen((contacts) {
      setState(() => _contacts = contacts);
      // Keep Siri's vocabulary and the Intents extension snapshot current,
      // using the names as saved in the device address book (like everywhere).
      _syncSiriContacts();
      // Flush a Siri request that arrived before Dart was listening — only
      // once contacts exist, so the uid can resolve.
      if (!siriFlushed) {
        siriFlushed = true;
        _s.intents.ready();
      }
    });

    _siriSub = _s.intents.startCallRequests.listen((request) {
      // Same two sources the vocabulary was built from, or Siri could match a
      // name it was taught and then fail to find the person behind it.
      final match = [..._contacts, ..._discovered]
          .where((c) => c.uid == request.contactUid);
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

  void _retryBootstrap() {
    setState(() => _bootstrapFailed = false);
    _bootstrap();
  }

  /// Unregister this device's push token before signing out, so it stops
  /// ringing for the account it's leaving (a signed-out device must not keep
  /// receiving its calls).
  Future<void> _signOut() async {
    await _s.pushRegistrar.unregister();
    await _s.auth.signOut();
  }

  /// Permanently delete the account (Guideline 5.1.1(v)). Unregister this
  /// device's push token first (also cancels the rotation listeners), then the
  /// backend wipes all remaining data and the Auth user; the auth-state stream
  /// then returns the app to the activation screen. Rethrows so Settings can
  /// show a retry message on failure.
  Future<void> _deleteAccount() async {
    await _s.pushRegistrar.unregister();
    await _s.auth.deleteAccount();
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
    _bootTimeout?.cancel();
    _profileBootSub?.cancel();
    _signInEmailSub?.cancel();
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
      if (_bootstrapFailed) {
        return _LoadError(
          onRetry: _retryBootstrap,
          onUseAnotherCode: _signOut,
        );
      }
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
      signInEmail: _signInEmail,
      discovery: _s.discovery,
      onCall: (contact, {required video}) => engine.startCall(contact, video: video),
      onSignOut: _signOut,
      onSaveName: (name) => _s.users.updateDisplayName(profile.uid, name),
      onReport: (message) => _s.users.submitSafetyReport(profile.uid, message),
      onDeleteAccount: _deleteAccount,
    );
  }
}

/// Shown when the initial profile load fails or times out, so the app can never
/// hang on a spinner (App Store rejection 2.1) — offers a retry.
class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry, required this.onUseAnotherCode});

  final VoidCallback onRetry;
  final VoidCallback onUseAnotherCode;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Mod.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(Mod.s6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(loc.loadError,
                    textAlign: TextAlign.center, style: Mod.body()),
                const SizedBox(height: Mod.s6),
                Semantics(
                  button: true,
                  label: loc.retry,
                  child: InkWell(
                    onTap: onRetry,
                    child: Container(
                      color: Mod.accent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: Mod.s8, vertical: 16),
                      child: ExcludeSemantics(
                        child: Text(loc.retry, style: Mod.button()),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Mod.s4),
                // Escape hatch: sign out back to the activation screen so a
                // different code can be entered if this account is stuck.
                Semantics(
                  button: true,
                  label: loc.useAnotherCode,
                  child: InkWell(
                    onTap: onUseAnotherCode,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: Mod.s4, vertical: 12),
                      child: ExcludeSemantics(
                        child: Text(loc.useAnotherCode,
                            style: Mod.name(color: Mod.accent)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
