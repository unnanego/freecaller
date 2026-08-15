import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:freecaller/l10n/app_localizations.dart';
import 'package:share_plus/share_plus.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import '../data/user_repo.dart';
import '../services/photo_picker.dart';
import 'contact_access_sheet.dart';
import 'phone_formatter.dart';
import 'theme/modernist.dart';

/// Profile + account. The owner edits their own name, number and picture here;
/// the sign-in address moves through a code mailed to the new mailbox, and
/// sign-out and deletion are guarded by confirmations.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.profile,
    required this.signInEmail,
    required this.discovery,
    required this.onSignOut,
    required this.onSaveName,
    required this.onSavePhone,
    required this.onSaveAvatar,
    required this.onRemoveAvatar,
    required this.onRequestEmailChange,
    required this.onConfirmEmailChange,
    required this.onReport,
    required this.onDeleteAccount,
  });

  final UserProfile profile;
  final String? signInEmail;
  final ContactDiscoveryRepo discovery;
  final Future<void> Function() onSignOut;
  final Future<void> Function(String name) onSaveName;
  final Future<void> Function(String phone) onSavePhone;
  final Future<void> Function(Uint8List bytes, String filename) onSaveAvatar;
  final Future<void> Function() onRemoveAvatar;
  final Future<void> Function(String email) onRequestEmailChange;
  final Future<void> Function(String code) onConfirmEmailChange;
  final Future<void> Function(String message) onReport;
  final Future<void> Function() onDeleteAccount;

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
          // Profile block — the picture is the tappable part.
          _AvatarBlock(
            profile: profile,
            onSave: onSaveAvatar,
            onRemove: onRemoveAvatar,
          ),
          Container(height: 2, color: Mod.divider),
          // Profile fields.
          Padding(
            padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s6, Mod.s2),
            child: Text(loc.sectionProfile, style: Mod.kicker(color: Mod.neutral600)),
          ),
          _EditableField(
            label: loc.fieldDisplayName,
            initial: profile.displayName,
            onSave: onSaveName,
          ),
          _EditableField(
            label: loc.fieldPhone,
            initial: profile.phone,
            hint: loc.fieldPhoneHint,
            keyboardType: TextInputType.phone,
            formatters: [PlusPhoneFormatter()],
            onSave: onSavePhone,
          ),
          const SizedBox(height: Mod.s4),
          Container(height: 2, color: Mod.divider),
          // Account.
          Padding(
            padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s4, Mod.s6, Mod.s2),
            child: Text(loc.sectionAccount, style: Mod.kicker(color: Mod.neutral600)),
          ),
          if (signInEmail != null) _signInEmailBlock(context, loc, signInEmail!),
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
          _row(
            context,
            label: loc.deleteAccountRow,
            labelColor: Mod.accent,
            onTap: () => _confirmDeleteAccount(context, loc),
          ),
        ],
      ),
    );
  }

  /// The address a sign-in code gets mailed to, + a share button so the user
  /// can save or relay it.
  Widget _signInEmailBlock(BuildContext context, AppLocalizations loc, String email) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s3, Mod.s6, Mod.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.signInEmailLabel, style: Mod.meta(color: Mod.neutral700)),
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
                  child: Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Mod.h2().copyWith(fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(width: Mod.s2),
              Semantics(
                button: true,
                label: loc.shareEmail,
                child: InkWell(
                  onTap: () => SharePlus.instance
                      .share(ShareParams(text: loc.signInEmailShare(email))),
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
          Text(loc.signInEmailHint, style: Mod.meta(color: Mod.neutral600)),
          const SizedBox(height: Mod.s3),
          Semantics(
            button: true,
            label: loc.emailChangeRow,
            child: InkWell(
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => _EmailChangeSheet(
                  currentEmail: email,
                  onRequest: onRequestEmailChange,
                  onConfirm: onConfirmEmailChange,
                ),
              ),
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Mod.bg,
                  border: Border.all(color: Mod.text, width: 2),
                ),
                child: ExcludeSemantics(
                  child: Text(loc.emailChangeRow, style: Mod.button(color: Mod.text)),
                ),
              ),
            ),
          ),
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

  /// Two-step confirmation, then permanent deletion. On success the auth state
  /// flips to signed-out and the app returns to the activation screen; on
  /// failure we surface a message so the user can retry.
  Future<void> _confirmDeleteAccount(
      BuildContext context, AppLocalizations loc) async {
    // Capture before the await so we don't touch context across the async gap.
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Mod.bg,
        title: Text(loc.deleteAccountConfirmTitle,
            style: Mod.h2().copyWith(fontSize: 20)),
        content: Text(loc.deleteAccountConfirmBody, style: Mod.body(color: Mod.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(loc.cancel, style: Mod.button(color: Mod.text)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(loc.deleteAccountConfirm, style: Mod.button(color: Mod.accent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await onDeleteAccount();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(loc.deleteAccountFailed)));
    }
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

/// One editable profile field — name or number. Saves on the button or on
/// keyboard done, and shows the server's own refusal underneath ("Этот номер
/// уже занят") rather than swallowing it: a number silently not saved is worse
/// than one that says why.
class _EditableField extends StatefulWidget {
  const _EditableField({
    required this.label,
    required this.initial,
    required this.onSave,
    this.hint,
    this.keyboardType,
    this.formatters,
  });

  final String label;
  final String initial;
  final Future<void> Function(String value) onSave;
  final String? hint;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? formatters;

  @override
  State<_EditableField> createState() => _EditableFieldState();
}

class _EditableFieldState extends State<_EditableField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  bool _saving = false;
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (_saving || value.isEmpty || value == widget.initial) return;
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _saving = true;
      _error = null;
      _saved = false;
    });
    try {
      await widget.onSave(value);
      if (mounted) {
        FocusScope.of(context).unfocus();
        setState(() => _saved = true);
      }
    } on ProfileConflictException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ProfileEditException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = loc.profileSaveFailed);
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
                    keyboardType: widget.keyboardType,
                    inputFormatters: widget.formatters,
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
          if (_error != null) ...[
            const SizedBox(height: 5),
            Text(_error!, style: Mod.meta(color: Mod.accent)),
          ] else if (_saved) ...[
            const SizedBox(height: 5),
            Text(loc.profileSaved, style: Mod.meta(color: Mod.neutral700)),
          ] else if (widget.hint != null) ...[
            const SizedBox(height: 5),
            Text(widget.hint!, style: Mod.meta(color: Mod.neutral600)),
          ],
        ],
      ),
    );
  }
}

/// The profile header: the picture, the name and the number — and the one
/// tappable thing in it, the picture.
///
/// The picker offers the camera as well as the library because the person most
/// likely to be given a photo here has never had one taken with this phone; the
/// image is scaled down before upload (the field caps at 2 MB, and every roster
/// read pays for what is stored).
class _AvatarBlock extends StatefulWidget {
  const _AvatarBlock({
    required this.profile,
    required this.onSave,
    required this.onRemove,
  });

  final UserProfile profile;
  final Future<void> Function(Uint8List bytes, String filename) onSave;
  final Future<void> Function() onRemove;

  @override
  State<_AvatarBlock> createState() => _AvatarBlockState();
}

class _AvatarBlockState extends State<_AvatarBlock> {
  bool _busy = false;
  String? _error;

  Future<void> _choose() async {
    if (_busy) return;
    final loc = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<_AvatarAction>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _AvatarActionSheet(hasPhoto: widget.profile.avatarUrl.isNotEmpty),
    );
    if (action == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (action == _AvatarAction.remove) {
        await widget.onRemove();
      } else {
        final picked = await const ProfilePhotoPicker()
            .pick(camera: action == _AvatarAction.camera);
        if (picked == null) {
          if (mounted) setState(() => _busy = false);
          return; // cancelled in the OS picker
        }
        await widget.onSave(picked.bytes, picked.filename);
      }
    } on PhotoPickerDenied {
      if (mounted) setState(() => _error = loc.photoCameraDenied);
    } on ProfileEditException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = loc.photoFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final profile = widget.profile;
    return Padding(
      padding: const EdgeInsets.all(Mod.s6),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: profile.avatarUrl.isEmpty ? loc.photoAdd : loc.photoChange,
            child: InkWell(
              onTap: _choose,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ExcludeSemantics(
                    child: InitialsTile(
                      name: profile.displayName,
                      size: 88,
                      imageUrl: profile.avatarUrl,
                    ),
                  ),
                  if (_busy)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Mod.accent),
                    ),
                ],
              ),
            ),
          ),
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
                const SizedBox(height: 6),
                Text(
                  _error ?? (profile.avatarUrl.isEmpty ? loc.photoAdd : loc.photoChange),
                  style: Mod.meta(color: _error != null ? Mod.accent : Mod.neutral600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _AvatarAction { camera, gallery, remove }

/// Where the picture comes from — camera, library, or gone.
class _AvatarActionSheet extends StatelessWidget {
  const _AvatarActionSheet({required this.hasPhoto});

  final bool hasPhoto;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Container(
      color: Mod.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s6, Mod.s6, Mod.s3),
              child: Text(loc.photoTitle, style: Mod.h2()),
            ),
            _option(context, loc.photoTake, Icons.photo_camera_outlined,
                _AvatarAction.camera),
            _option(context, loc.photoChoose, Icons.photo_library_outlined,
                _AvatarAction.gallery),
            if (hasPhoto)
              _option(context, loc.photoRemove, Icons.delete_outline,
                  _AvatarAction.remove,
                  color: Mod.accent),
            const SizedBox(height: Mod.s4),
          ],
        ),
      ),
    );
  }

  Widget _option(BuildContext context, String label, IconData icon,
      _AvatarAction action,
      {Color? color}) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: () => Navigator.of(context).pop(action),
        child: Container(
          decoration:
              BoxDecoration(border: Border(top: BorderSide(color: Mod.rowDivider))),
          padding: const EdgeInsets.symmetric(horizontal: Mod.s6, vertical: Mod.s4),
          child: ExcludeSemantics(
            child: Row(
              children: [
                Icon(icon, size: 22, color: color ?? Mod.text),
                const SizedBox(width: Mod.s3),
                Text(label, style: Mod.name(color: color ?? Mod.text)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Moving the account to another mailbox, in two steps: ask for a code, then
/// hand it back. The old address keeps working until the second step succeeds,
/// which is the whole point of doing it this way — the address is the only
/// credential this app has.
class _EmailChangeSheet extends StatefulWidget {
  const _EmailChangeSheet({
    required this.currentEmail,
    required this.onRequest,
    required this.onConfirm,
  });

  final String currentEmail;
  final Future<void> Function(String email) onRequest;
  final Future<void> Function(String code) onConfirm;

  @override
  State<_EmailChangeSheet> createState() => _EmailChangeSheetState();
}

class _EmailChangeSheetState extends State<_EmailChangeSheet> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _codeSent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final email = _email.text.trim();
    if (_busy || email.isEmpty) return;
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRequest(email);
      if (mounted) setState(() => _codeSent = true);
    } on ProfileConflictException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ProfileEditException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = loc.emailChangeFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (_busy || code.isEmpty) return;
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm(code);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(content: Text(loc.emailChanged(_email.text.trim()))),
      );
    } on ProfileConflictException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ProfileEditException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = loc.emailChangeFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        color: Mod.surface,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s6, Mod.s6, Mod.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _codeSent ? _codeStep(loc) : _addressStep(loc),
          ),
        ),
      ),
    );
  }

  List<Widget> _addressStep(AppLocalizations loc) => [
        Text(loc.emailChangeTitle, style: Mod.h2()),
        const SizedBox(height: 2),
        Text(loc.emailChangeInfo, style: Mod.meta(color: Mod.neutral700)),
        const SizedBox(height: Mod.s4),
        _field(loc.emailChangeNew, _email, TextInputType.emailAddress,
            fieldKey: const ValueKey('newEmail')),
        const SizedBox(height: 5),
        Text(loc.emailChangeCurrent(widget.currentEmail),
            style: Mod.meta(color: Mod.neutral600)),
        ...?_errorLine(),
        const SizedBox(height: Mod.s6),
        _button(loc.emailChangeSend, _request),
      ];

  List<Widget> _codeStep(AppLocalizations loc) => [
        Text(loc.emailChangeCodeTitle, style: Mod.h2()),
        const SizedBox(height: 2),
        Text(loc.emailChangeCodeInfo(_email.text.trim()),
            style: Mod.meta(color: Mod.neutral700)),
        const SizedBox(height: Mod.s4),
        _field(
          loc.emailChangeCode,
          _code,
          const TextInputType.numberWithOptions(signed: false, decimal: false),
          fieldKey: const ValueKey('code'),
          autofocus: true,
          formatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(8),
          ],
        ),
        ...?_errorLine(),
        const SizedBox(height: Mod.s6),
        _button(loc.emailChangeConfirm, _confirm),
        const SizedBox(height: Mod.s3),
        Semantics(
          button: true,
          label: loc.emailChangeBack,
          child: InkWell(
            onTap: _busy
                ? null
                : () => setState(() {
                      _codeSent = false;
                      _error = null;
                      _code.clear();
                    }),
            child: Container(
              height: 44,
              alignment: Alignment.center,
              child: ExcludeSemantics(
                child: Text(loc.emailChangeBack,
                    style: Mod.button(color: Mod.neutral700)),
              ),
            ),
          ),
        ),
      ];

  List<Widget>? _errorLine() => _error == null
      ? null
      : [
          const SizedBox(height: Mod.s3),
          Text(_error!, style: Mod.meta(color: Mod.accent)),
        ];

  /// [fieldKey] is load-bearing, not decoration. Both steps render one
  /// TextField at the same spot, so without distinct keys Flutter updates the
  /// element in place — and a keyboardType change is ignored on a field that
  /// already holds focus, which left the email keyboard up for an 8-digit code.
  /// The activation screen learned this first; see its `_field`.
  Widget _field(
    String label,
    TextEditingController controller,
    TextInputType type, {
    Key? fieldKey,
    bool autofocus = false,
    List<TextInputFormatter>? formatters,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Mod.meta(color: Mod.neutral700)),
        const SizedBox(height: 5),
        Container(
          decoration: BoxDecoration(
            color: Mod.bg,
            border: Border.all(color: Mod.divider, width: 2),
          ),
          child: TextField(
            key: fieldKey,
            controller: controller,
            keyboardType: type,
            autofocus: autofocus,
            inputFormatters: formatters,
            style: Mod.body(color: Mod.text),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _button(String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 52,
            alignment: Alignment.center,
            color: Mod.accent,
            child: _busy
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
