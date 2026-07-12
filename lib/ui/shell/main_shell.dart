import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../../data/contact_discovery.dart';
import '../../data/models.dart';
import '../contacts_screen.dart';
import '../recents_screen.dart';
import '../settings_screen.dart';
import '../theme/modernist.dart';

/// The signed-in home: Recents · Contacts · Settings behind a bottom tab bar.
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.profile,
    required this.recents,
    required this.names,
    required this.loginCode,
    required this.discovery,
    required this.onCall,
    required this.onSignOut,
    required this.onSaveName,
  });

  final UserProfile profile;
  final List<CallDoc> recents;
  final ContactNames names;
  final String? loginCode;
  final ContactDiscoveryRepo discovery;
  final void Function(Contact contact, {required bool video}) onCall;
  final Future<void> Function() onSignOut;
  final Future<void> Function(String name) onSaveName;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 1; // default to Contacts

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Mod.bg,
      body: IndexedStack(
        index: _tab,
        children: [
          RecentsScreen(
            recents: widget.recents,
            names: widget.names,
            onCall: widget.onCall,
          ),
          ContactsScreen(discovery: widget.discovery, onCall: widget.onCall),
          SettingsScreen(
            profile: widget.profile,
            loginCode: widget.loginCode,
            discovery: widget.discovery,
            onSignOut: widget.onSignOut,
            onSaveName: widget.onSaveName,
          ),
        ],
      ),
      bottomNavigationBar: _TabBar(
        current: _tab,
        onTap: (i) => setState(() => _tab = i),
        labels: [loc.navRecents, loc.navContacts, loc.navSettings],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onTap, required this.labels});

  final int current;
  final ValueChanged<int> onTap;
  final List<String> labels;

  static const _icons = [Icons.access_time, Icons.people_outline, Icons.settings];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: Mod.divider, width: 2))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (var i = 0; i < 3; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == current,
                    label: labels[i],
                    child: InkWell(
                      onTap: () => onTap(i),
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_icons[i],
                                size: 22,
                                color: i == current ? Mod.accent : Mod.neutral600),
                            const SizedBox(height: 4),
                            Text(labels[i],
                                style: Mod.caption(
                                    color: i == current ? Mod.accent : Mod.neutral600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
