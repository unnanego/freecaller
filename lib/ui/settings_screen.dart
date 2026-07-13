import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:share_plus/share_plus.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import 'contact_access_sheet.dart';
import 'theme/modernist.dart';

/// Profile + account. Shows the reusable login code (needed to sign back in on
/// another device) and guards sign-out with a confirmation.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.profile,
    required this.loginCode,
    required this.discovery,
    required this.onSignOut,
    required this.onSaveName,
    required this.onReport,
  });

  final UserProfile profile;
  final String? loginCode;
  final ContactDiscoveryRepo discovery;
  final Future<void> Function() onSignOut;
  final Future<void> Function(String name) onSaveName;
  final Future<void> Function(String message) onReport;

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
          if (loginCode != null) _loginCodeBlock(context, loc, loginCode!),
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
            label: loc.safetyRow,
            trailing: const Icon(Icons.chevron_right, color: Mod.text),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _SafetyReportSheet(onReport: onReport),
            ),
          ),
          _row(
            context,
            label: loc.signOut,
            labelColor: Mod.accent,
            onTap: () => _confirmSignOut(context, loc),
          ),
        ],
      ),
    );
  }

  /// The reusable login code + a share button, so the user can save/relay it.
  Widget _loginCodeBlock(BuildContext context, AppLocalizations loc, String code) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s3, Mod.s6, Mod.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.loginCodeLabel, style: Mod.meta(color: Mod.neutral700)),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 52,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Mod.surface,
                    border: Border.all(color: Mod.divider, width: 2),
                  ),
                  child: Text(code,
                      style: Mod.h2().copyWith(fontSize: 28, letterSpacing: 4)),
                ),
              ),
              const SizedBox(width: Mod.s2),
              Semantics(
                button: true,
                label: loc.shareCode,
                child: InkWell(
                  onTap: () => SharePlus.instance
                      .share(ShareParams(text: loc.loginCodeShare(code))),
                  child: Container(
                    height: 52,
                    width: 52,
                    alignment: Alignment.center,
                    color: Mod.accent,
                    child: const ExcludeSemantics(
                      child: Icon(Icons.ios_share, color: Mod.bg, size: 22),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(loc.loginCodeHint, style: Mod.meta(color: Mod.neutral600)),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, AppLocalizations loc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Mod.bg,
        title: Text(loc.signOutConfirmTitle, style: Mod.h2().copyWith(fontSize: 20)),
        content: Text(loc.signOutConfirmBody, style: Mod.body(color: Mod.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(loc.cancel, style: Mod.button(color: Mod.text)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(loc.signOut, style: Mod.button(color: Mod.accent)),
          ),
        ],
      ),
    );
    if (confirmed == true) await onSignOut();
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

/// In-app child-safety report: a text field + Send, filed straight to the
/// backend so a user can report a concern **without leaving the app** (store
/// child-safety requirement). Shows a thank-you state on success.
class _SafetyReportSheet extends StatefulWidget {
  const _SafetyReportSheet({required this.onReport});

  final Future<void> Function(String message) onReport;

  @override
  State<_SafetyReportSheet> createState() => _SafetyReportSheetState();
}

class _SafetyReportSheetState extends State<_SafetyReportSheet> {
  final _text = TextEditingController();
  bool _sending = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final msg = _text.text.trim();
    if (_sending || msg.isEmpty) return;
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onReport(msg);
      if (mounted) setState(() { _sending = false; _sent = true; });
    } catch (_) {
      if (mounted) setState(() { _sending = false; _error = loc.safetyFailed; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        color: Mod.bg,
        padding: const EdgeInsets.all(Mod.s6),
        child: SafeArea(top: false, child: _sent ? _thanks(loc) : _form(loc)),
      ),
    );
  }

  Widget _thanks(AppLocalizations loc) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.safetyTitle, style: Mod.h2()),
          const SizedBox(height: Mod.s4),
          Text(loc.safetyThanks, style: Mod.body(color: Mod.text)),
          const SizedBox(height: Mod.s6),
          _button(loc.close, () => Navigator.of(context).pop()),
        ],
      );

  Widget _form(AppLocalizations loc) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.safetyTitle, style: Mod.h2()),
          const SizedBox(height: Mod.s3),
          Text(loc.safetyInfo, style: Mod.meta(color: Mod.neutral700)),
          const SizedBox(height: Mod.s4),
          Container(
            decoration: BoxDecoration(
              color: Mod.surface,
              border: Border.all(color: Mod.divider, width: 2),
            ),
            child: TextField(
              controller: _text,
              minLines: 3,
              maxLines: 6,
              style: Mod.body(color: Mod.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: loc.safetyHint,
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Mod.s2),
            Text(_error!, style: Mod.meta(color: Mod.accent)),
          ],
          const SizedBox(height: Mod.s4),
          _button(loc.safetySend, _send, busy: _sending),
        ],
      );

  Widget _button(String label, VoidCallback onTap, {bool busy = false}) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 52,
            alignment: Alignment.center,
            color: Mod.accent,
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Mod.bg),
                  )
                : ExcludeSemantics(child: Text(label, style: Mod.button())),
          ),
        ),
      );
}
