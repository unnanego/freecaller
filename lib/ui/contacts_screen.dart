import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import 'contact_access_sheet.dart';
import 'theme/modernist.dart';

/// People from the OS address book who also use the app, auto-matched by phone
/// number. No manual add — the shield opens the granular access sheet.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, required this.discovery, required this.onCall});

  final ContactDiscoveryRepo discovery;
  final void Function(Contact contact, {required bool video}) onCall;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> with WidgetsBindingObserver {
  bool _loading = true;
  bool _denied = false;
  List<DiscoveredContact> _onApp = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check after the user returns from the system Settings app, where they
    // may have just granted contacts access.
    if (state == AppLifecycleState.resumed && _denied) _load();
  }

  Future<void> _grantAccess() async {
    if (await widget.discovery.ensureAccess()) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await widget.discovery.loadAllowedOnApp();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _denied = result == null;
      _onApp = result ?? const [];
    });
  }

  Future<void> _openAccessSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ContactAccessSheet(discovery: widget.discovery),
    );
    _load(); // allow-list may have changed
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(loc),
          Container(height: 2, color: Mod.divider),
          Expanded(child: _body(loc)),
        ],
      ),
    );
  }

  Widget _header(AppLocalizations loc) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s4, Mod.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(loc.contactsTitle, style: Mod.h2()),
                const SizedBox(height: 2),
                Text(loc.contactsOnApp(_onApp.length), style: Mod.meta()),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: loc.contactAccessRow,
            child: InkWell(
              onTap: _openAccessSheet,
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(border: Border.all(color: Mod.divider, width: 2)),
                child: const ExcludeSemantics(
                  child: Icon(Icons.shield_outlined, color: Mod.text, size: 22),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(AppLocalizations loc) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Mod.accent));
    }
    if (_denied) return _permissionCta(loc);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: double.infinity,
          color: Mod.surface,
          padding: const EdgeInsets.symmetric(horizontal: Mod.s6, vertical: Mod.s3),
          child: Text(loc.contactsMatchInfo, style: Mod.meta(color: Mod.neutral700)),
        ),
        Expanded(
          child: _onApp.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Mod.s8),
                    child: Text(loc.contactsEmpty,
                        textAlign: TextAlign.center, style: Mod.body()),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: _onApp.length,
                  itemBuilder: (_, i) => _ContactRow(
                    contact: _onApp[i],
                    onCall: widget.onCall,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _permissionCta(AppLocalizations loc) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Mod.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, color: Mod.neutral500, size: 48),
            const SizedBox(height: Mod.s4),
            Text(loc.contactsPermissionInfo,
                textAlign: TextAlign.center, style: Mod.body()),
            const SizedBox(height: Mod.s6),
            _PrimaryButton(label: loc.grantAccess, icon: Icons.check, onTap: _grantAccess),
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.contact, required this.onCall});

  final DiscoveredContact contact;
  final void Function(Contact contact, {required bool video}) onCall;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Mod.rowDivider))),
      padding: const EdgeInsets.symmetric(horizontal: Mod.s6, vertical: Mod.s3),
      child: Row(
        children: [
          InitialsTile(name: contact.name),
          const SizedBox(width: Mod.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.name, style: Mod.name(), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(width: 6, height: 6, color: Mod.accent),
                    const SizedBox(width: 6),
                    Text(loc.onAppBadge, style: Mod.kicker()),
                  ],
                ),
              ],
            ),
          ),
          _ActionButton(
            semanticLabel: loc.callContact(contact.name),
            icon: Icons.call,
            filled: false,
            onTap: () => onCall(contact.toContact(), video: false),
          ),
          const SizedBox(width: Mod.s2),
          _ActionButton(
            semanticLabel: loc.videoCallContact(contact.name),
            icon: Icons.videocam,
            filled: true,
            onTap: () => onCall(contact.toContact(), video: true),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.semanticLabel,
    required this.icon,
    required this.filled,
    required this.onTap,
  });

  final String semanticLabel;
  final IconData icon;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? Mod.accent : null,
            border: filled ? null : Border.all(color: Mod.divider, width: 2),
          ),
          child: ExcludeSemantics(
            child: Icon(icon, size: 20, color: filled ? Mod.bg : Mod.text),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: Mod.accent,
          padding: const EdgeInsets.symmetric(horizontal: Mod.s4, vertical: 17),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(child: Icon(icon, color: Mod.bg, size: 20)),
              const SizedBox(width: Mod.s2),
              ExcludeSemantics(child: Text(label, style: Mod.button())),
            ],
          ),
        ),
      ),
    );
  }
}
