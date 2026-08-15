import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/contact_discovery.dart';
import '../data/models.dart';
import 'phone_formatter.dart';
import 'theme/modernist.dart';

/// People from the OS address book who also use the app, auto-matched by phone
/// number.
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
  bool _needsConsent = false;
  /// Only consulted while [_denied]: decides whether the CTA can still ask the
  /// OS, or has nothing to offer but a link to Settings.
  ContactAccess _access = ContactAccess.denied;
  List<DiscoveredContact> _onApp = const [];
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.discovery.revision.addListener(_reload);
    _load();
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    widget.discovery.revision.removeListener(_reload);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A quiet reload, coalesced. Each tap in the access sheet is its own
  /// allow-list write, and a reload costs a full address-book read plus the
  /// server match — so settle first and rescan once.
  void _reload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _load(quiet: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Rescan on every return to the app, not just after a permission change.
    // The address book is edited in another app entirely, and nothing tells us
    // it changed — so a contact added in the Contacts app only showed up here
    // once something else happened to trigger a load (opening the invite sheet
    // was the one path that did), which read as "the app never rescans".
    if (state == AppLifecycleState.resumed) _reload();
  }

  /// Ask the OS for contacts access, once, and accept the answer.
  ///
  /// Nothing happens on a refusal beyond remembering it: no second prompt, and
  /// above all no bounce into Settings (App Store 5.1.1 — a permission prompt is
  /// the user's decision to make). The CTA below then explains what the list
  /// needs and offers a Settings link they can choose to tap.
  Future<void> _requestAccess() async {
    final access = await widget.discovery.requestAccess();
    if (!mounted) return;
    if (access == ContactAccess.granted) {
      await _load();
      return;
    }
    // [_denied] too, or the body falls through to the list and an empty list
    // reads as "none of your contacts use the app" — when the truth is that we
    // can't look.
    setState(() {
      _access = access;
      _denied = true;
      _onApp = const [];
    });
  }

  /// The user tapped the consent button: record their agreement to upload
  /// numbers for matching, then request OS contacts access and load.
  Future<void> _consentAndLoad() async {
    await widget.discovery.grantUploadConsent();
    if (!mounted) return;
    setState(() => _needsConsent = false);
    await _requestAccess();
  }

  /// [quiet] reloads in place, without the spinner: a rescan on resume or after
  /// an allow-list change replaces a list the user is already looking at, and
  /// blanking it to a spinner every time they come back to the app reads as the
  /// screen reloading for no reason.
  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    // Nothing is uploaded until the user has explicitly consented — show the
    // consent screen first (Guideline 5.1.2).
    if (!await widget.discovery.hasUploadConsent()) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _needsConsent = true;
        _denied = false;
        _onApp = const [];
      });
      return;
    }
    final List<DiscoveredContact>? result;
    try {
      result = await widget.discovery.loadAllowedOnApp();
    } on ContactMatchException {
      // Couldn't reach the backend. Keep whatever is already on screen: a
      // rescan that failed must never present itself as "nobody uses the app",
      // and this now runs on every resume, so a single dropped request would
      // otherwise empty the list under the user.
      if (mounted) setState(() => _loading = false);
      return;
    }
    // A null result means access is missing; which CTA to show depends on
    // whether the OS is still willing to ask.
    final access =
        result == null ? await widget.discovery.accessStatus() : ContactAccess.granted;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _needsConsent = false;
      _denied = result == null;
      _access = access;
      _onApp = result ?? const [];
    });
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
            label: loc.inviteTitle,
            child: InkWell(
              onTap: _openInviteSheet,
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                color: Mod.accent,
                child: const ExcludeSemantics(
                  child: Icon(Icons.person_add_alt_1, color: Mod.bg, size: 22),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openInviteSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _InviteSheet(discovery: widget.discovery),
    );
    _load(); // the invited person may now appear as a contact
  }

  Widget _body(AppLocalizations loc) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Mod.accent));
    }
    if (_needsConsent) return _consentCta(loc);
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

  /// Explicit consent before any address-book number leaves the device
  /// (Guideline 5.1.2). Explains that numbers are sent to our server purely to
  /// find who already uses the app.
  Widget _consentCta(AppLocalizations loc) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Mod.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.group_add_outlined, color: Mod.neutral500, size: 48),
            const SizedBox(height: Mod.s4),
            Text(loc.contactsConsentTitle,
                textAlign: TextAlign.center, style: Mod.h2().copyWith(fontSize: 20)),
            const SizedBox(height: Mod.s3),
            Text(loc.contactsConsentBody,
                textAlign: TextAlign.center, style: Mod.body()),
            const SizedBox(height: Mod.s6),
            _PrimaryButton(
              // Neutral wording, deliberately: the OS prompt follows this
              // button, and a pre-permission screen must explain rather than
              // campaign (App Store 5.1.1).
              label: loc.contactsConsentAgree,
              icon: Icons.arrow_forward,
              onTap: _consentAndLoad,
            ),
          ],
        ),
      ),
    );
  }

  /// What the list needs in order to have anything in it.
  ///
  /// Two shapes, and the difference is the whole point of App Store 5.1.1: while
  /// the OS is still willing to prompt, the button asks it — labelled neutrally,
  /// because a pre-permission button must not lobby for a yes. Once the answer
  /// is settled, there is nothing left to ask and the screen says so, with a
  /// link to Settings the user can take or ignore.
  Widget _permissionCta(AppLocalizations loc) {
    final blocked = _access == ContactAccess.blocked;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Mod.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, color: Mod.neutral500, size: 48),
            const SizedBox(height: Mod.s4),
            Text(
              blocked ? loc.contactsAccessBlocked : loc.contactsPermissionInfo,
              textAlign: TextAlign.center,
              style: Mod.body(),
            ),
            const SizedBox(height: Mod.s6),
            blocked
                ? _PrimaryButton(
                    label: loc.openDeviceSettings,
                    icon: Icons.settings_outlined,
                    onTap: widget.discovery.openSystemSettings,
                  )
                : _PrimaryButton(
                    label: loc.continueAction,
                    icon: Icons.arrow_forward,
                    onTap: _requestAccess,
                  ),
          ],
        ),
      ),
    );
  }
}

/// Invite sheet: enter a name, phone and email → the server provisions the
/// person, mutual-links you both, and emails them which address to sign in
/// with. Nothing to pass along by hand: the sign-in code is mailed to that
/// address when they ask for it.
class _InviteSheet extends StatefulWidget {
  const _InviteSheet({required this.discovery});

  final ContactDiscoveryRepo discovery;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  // Prefilled with "+"; the formatter keeps exactly one leading "+" so the
  // number always ends up in international E.164 format.
  final _phone = TextEditingController(text: '+');
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// Fill the form from the OS contact picker, so the inviter doesn't have to
  /// copy a number out of their address book by hand.
  ///
  /// Name and number always come from the pick (that is what was asked for);
  /// the email only fills a field the user hasn't typed into, since a contact's
  /// stored address is a guess at where the invitation should go.
  Future<void> _pickFromContacts() async {
    final loc = AppLocalizations.of(context)!;
    final PickedContact? picked;
    try {
      picked = await widget.discovery.pickContact();
    } on ContactPickDeniedException {
      if (mounted) setState(() => _error = loc.invitePickDenied);
      return;
    } catch (_) {
      if (mounted) setState(() => _error = loc.invitePickFailed);
      return;
    }
    if (picked == null || !mounted) return; // cancelled
    final contact = picked;
    if (contact.phones.isEmpty) {
      setState(() => _error = loc.invitePickNoNumber);
      return;
    }
    final phone = contact.phones.length == 1
        ? contact.phones.first
        : await _chooseNumber(contact);
    if (phone == null || !mounted) return;
    final email = contact.email;
    setState(() {
      _error = null;
      if (contact.name.isNotEmpty) _name.text = contact.name;
      _phone.text = phone;
      if (email != null && _email.text.trim().isEmpty) _email.text = email;
    });
  }

  /// Which of a contact's numbers to invite. Only shown when there is a real
  /// choice to make.
  Future<String?> _chooseNumber(PickedContact picked) {
    final loc = AppLocalizations.of(context)!;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        color: Mod.surface,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s6, Mod.s6, Mod.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(loc.invitePickNumber, style: Mod.h2()),
              if (picked.name.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(picked.name, style: Mod.meta(color: Mod.neutral700)),
              ],
              const SizedBox(height: Mod.s4),
              for (final phone in picked.phones)
                Semantics(
                  button: true,
                  label: phone,
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(phone),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: Mod.rowDivider)),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: Mod.s4),
                      child: ExcludeSemantics(
                        child: Text(phone, style: Mod.name()),
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

  Future<void> _invite() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final email = _email.text.trim();
    if (_sending || name.isEmpty || phone.isEmpty || email.isEmpty) return;
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final emailed = await widget.discovery.invite(name, phone, email);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      // The account exists by now either way; the two messages differ in
      // whether the invitee was told, or the inviter has to tell them.
      messenger.showSnackBar(SnackBar(
        content: Text(emailed ? loc.inviteSent(email) : loc.inviteSentNoEmail(email)),
      ));
    } on InviteExistsException {
      // Stay on the sheet: the fix is to change a field, not to retry.
      if (mounted) {
        setState(() {
          _sending = false;
          _error = loc.inviteExists;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = loc.inviteFailed;
        });
      }
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
        // Scrollable: three fields, their hints, the pick button and an error
        // line add up to more than a small phone has left over once the
        // keyboard is up — and a form that overflows loses its own submit
        // button.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s6, Mod.s6, Mod.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(loc.inviteTitle, style: Mod.h2()),
              const SizedBox(height: 2),
              Text(loc.inviteInfo, style: Mod.meta(color: Mod.neutral700)),
              const SizedBox(height: Mod.s4),
              Semantics(
                button: true,
                label: loc.invitePickContact,
                child: InkWell(
                  onTap: _pickFromContacts,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Mod.bg,
                      border: Border.all(color: Mod.text, width: 2),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.contacts_outlined, size: 20, color: Mod.text),
                          const SizedBox(width: Mod.s2),
                          Text(loc.invitePickContact,
                              style: Mod.button(color: Mod.text)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Mod.s4),
              _field(loc.inviteName, _name, TextInputType.name),
              const SizedBox(height: Mod.s3),
              _field(loc.invitePhone, _phone, TextInputType.phone,
                  formatters: [PlusPhoneFormatter()]),
              const SizedBox(height: 5),
              Text(loc.invitePhoneHint, style: Mod.meta(color: Mod.neutral700)),
              const SizedBox(height: Mod.s3),
              _field(loc.inviteEmail, _email, TextInputType.emailAddress),
              const SizedBox(height: 5),
              Text(loc.inviteEmailHint, style: Mod.meta(color: Mod.neutral700)),
              if (_error != null) ...[
                const SizedBox(height: Mod.s3),
                Text(_error!, style: Mod.meta(color: Mod.accent)),
              ],
              const SizedBox(height: Mod.s6),
              Semantics(
                button: true,
                label: loc.inviteTitle,
                child: InkWell(
                  onTap: _invite,
                  child: Container(
                    color: Mod.accent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    alignment: Alignment.center,
                    child: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2, color: Mod.bg),
                          )
                        : ExcludeSemantics(
                            child: Text(loc.inviteTitle, style: Mod.button())),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController controller, TextInputType type,
      {List<TextInputFormatter>? formatters}) {
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
            controller: controller,
            keyboardType: type,
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
          InitialsTile(name: contact.name, imageUrl: contact.avatarUrl),
          const SizedBox(width: Mod.s3),
          Expanded(
            child: Text(contact.name,
                style: Mod.name(), maxLines: 1, overflow: TextOverflow.ellipsis),
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
