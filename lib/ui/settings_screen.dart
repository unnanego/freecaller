import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import 'contact_access_sheet.dart';
import 'theme/modernist.dart';

/// Profile + account. Display name and phone are provisioned server-side (user
/// docs are admin-only), so they're read-only here for now; editing them is a
/// follow-up that needs a backend write path.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.profile,
    required this.discovery,
    required this.onSignOut,
    required this.onSaveName,
  });

  final UserProfile profile;
  final ContactDiscoveryRepo discovery;
  final Future<void> Function() onSignOut;
  final Future<void> Function(String name) onSaveName;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s6, Mod.s3),
            child: Text(loc.settingsTitle, style: Mod.h2()),
          ),
          Container(height: 2, color: Mod.divider),
          // Profile block.
          Padding(
            padding: const EdgeInsets.all(Mod.s6),
            child: Row(
              children: [
                InitialsTile(name: profile.displayName, size: 88),
                const SizedBox(width: Mod.s4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(profile.displayName,
                          style: Mod.h2().copyWith(fontSize: 22),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(profile.phone, style: Mod.meta()),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(height: 2, color: Mod.divider),
          // Profile fields (read-only for now).
          Padding(
            padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s6, Mod.s2),
            child: Text(loc.sectionProfile, style: Mod.kicker(color: Mod.neutral600)),
          ),
          _EditableNameField(
            label: loc.fieldDisplayName,
            initial: profile.displayName,
            onSave: onSaveName,
          ),
          _readonlyField(loc.fieldPhone, profile.phone),
          const SizedBox(height: Mod.s4),
          Container(height: 2, color: Mod.divider),
          // Account.
          Padding(
            padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s6, Mod.s2),
            child: Text(loc.sectionAccount, style: Mod.kicker(color: Mod.neutral600)),
          ),
          _row(
            context,
            label: loc.contactAccessRow,
            trailing: const Icon(Icons.chevron_right, color: Mod.text),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => ContactAccessSheet(discovery: discovery),
            ),
          ),
          _row(
            context,
            label: loc.signOut,
            labelColor: Mod.accent,
            onTap: onSignOut,
          ),
        ],
      ),
    );
  }

  Widget _readonlyField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s2, Mod.s6, Mod.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Mod.meta(color: Mod.neutral700)),
          const SizedBox(height: 5),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 46),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: Mod.surface,
              border: Border.all(color: Mod.divider, width: 2),
            ),
            child: Text(value, style: Mod.body(color: Mod.text)),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required String label,
    Color? labelColor,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Mod.rowDivider))),
          padding: const EdgeInsets.symmetric(horizontal: Mod.s6, vertical: Mod.s4),
          child: ExcludeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(label, style: Mod.name(color: labelColor ?? Mod.text)),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Editable profile display name — the one field the owner may change (rules
/// restrict the write to `displayName`). Saves on the button or keyboard done.
class _EditableNameField extends StatefulWidget {
  const _EditableNameField({
    required this.label,
    required this.initial,
    required this.onSave,
  });

  final String label;
  final String initial;
  final Future<void> Function(String name) onSave;

  @override
  State<_EditableNameField> createState() => _EditableNameFieldState();
}

class _EditableNameFieldState extends State<_EditableNameField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (_saving || name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(name);
      if (mounted) FocusScope.of(context).unfocus();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s2, Mod.s6, Mod.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: Mod.meta(color: Mod.neutral700)),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 46),
                  decoration: BoxDecoration(
                    color: Mod.surface,
                    border: Border.all(color: Mod.divider, width: 2),
                  ),
                  child: TextField(
                    controller: _controller,
                    style: Mod.body(color: Mod.text),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Mod.s2),
              Semantics(
                button: true,
                label: loc.save,
                child: InkWell(
                  onTap: _save,
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.symmetric(horizontal: Mod.s4),
                    alignment: Alignment.center,
                    color: Mod.accent,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Mod.bg),
                          )
                        : ExcludeSemantics(
                            child: Text(loc.save, style: Mod.button())),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
