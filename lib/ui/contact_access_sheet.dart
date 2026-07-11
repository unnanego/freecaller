import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/contact_discovery.dart';
import 'theme/modernist.dart';

/// The granular "which contacts can the app see" sheet. Lists every device
/// contact with on-app status and a per-contact allow toggle (persisted). Only
/// allowed contacts who use the app appear on the Contacts screen. Replaces an
/// in-app add-contact flow.
class ContactAccessSheet extends StatefulWidget {
  const ContactAccessSheet({super.key, required this.discovery});

  final ContactDiscoveryRepo discovery;

  @override
  State<ContactAccessSheet> createState() => _ContactAccessSheetState();
}

class _ContactAccessSheetState extends State<ContactAccessSheet> {
  bool _loading = true;
  List<DiscoveredContact> _all = const [];
  Set<String> _blocked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var all = await widget.discovery.loadDeviceContacts();
    if (all == null) {
      // Opened without access — prompt (or route to Settings), then retry.
      await widget.discovery.ensureAccess();
      all = await widget.discovery.loadDeviceContacts();
    }
    final blocked = await widget.discovery.blockedIds();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _all = all ?? const [];
      _blocked = blocked;
    });
  }

  void _toggle(DiscoveredContact c) {
    final allowed = _blocked.contains(c.deviceId); // currently blocked → allow
    widget.discovery.setAllowed(c.deviceId, allowed);
    setState(() {
      if (allowed) {
        _blocked.remove(c.deviceId);
      } else {
        _blocked.add(c.deviceId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final allowedCount = _all.where((c) => !_blocked.contains(c.deviceId)).length;
    return FractionallySizedBox(
      heightFactor: 0.82,
      child: Container(
        decoration: BoxDecoration(
          color: Mod.bg,
          border: Border(top: BorderSide(color: Mod.text, width: 2)),
        ),
        child: Column(
          children: [
            _header(loc),
            Container(
              width: double.infinity,
              color: Mod.surface,
              padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s3, Mod.s6, Mod.s3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.shield_outlined, color: Mod.accent, size: 18),
                  const SizedBox(width: Mod.s2),
                  Expanded(
                    child: Text(loc.accessInfo, style: Mod.meta(color: Mod.neutral700)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Mod.accent))
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: _all.length,
                      itemBuilder: (_, i) => _AccessRow(
                        contact: _all[i],
                        allowed: !_blocked.contains(_all[i].deviceId),
                        onToggle: () => _toggle(_all[i]),
                      ),
                    ),
            ),
            _doneButton(loc, allowedCount),
          ],
        ),
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
                Text(loc.accessKicker, style: Mod.kicker(color: Mod.neutral600)),
                const SizedBox(height: Mod.s1),
                Text(loc.accessTitle, style: Mod.h2().copyWith(fontSize: 22)),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: loc.close,
            child: InkWell(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(border: Border.all(color: Mod.divider, width: 2)),
                child: const ExcludeSemantics(child: Icon(Icons.close, size: 20)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _doneButton(AppLocalizations loc, int allowedCount) {
    return SafeArea(
      top: false,
      child: Semantics(
        button: true,
        label: loc.accessDone(allowedCount),
        child: InkWell(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: double.infinity,
            color: Mod.accent,
            padding: const EdgeInsets.symmetric(vertical: 18),
            alignment: Alignment.center,
            child: ExcludeSemantics(
              child: Text(loc.accessDone(allowedCount), style: Mod.button()),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccessRow extends StatelessWidget {
  const _AccessRow({
    required this.contact,
    required this.allowed,
    required this.onToggle,
  });

  final DiscoveredContact contact;
  final bool allowed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final status = contact.onApp ? loc.onAppBadge : loc.notOnAppBadge;
    return Semantics(
      button: true,
      checked: allowed,
      label: '${contact.name}. $status',
      child: InkWell(
        onTap: onToggle,
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Mod.rowDivider))),
          padding: const EdgeInsets.symmetric(horizontal: Mod.s6, vertical: Mod.s3),
          child: Row(
            children: [
              InitialsTile(name: contact.name),
              const SizedBox(width: Mod.s3),
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(contact.name,
                          style: Mod.name(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(
                        contact.onApp ? loc.onAppBadge : loc.notOnAppBadge,
                        style: contact.onApp
                            ? Mod.kicker()
                            : Mod.meta(color: Mod.neutral500),
                      ),
                    ],
                  ),
                ),
              ),
              ExcludeSemantics(
                child: Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: allowed ? Mod.accent : null,
                    border: allowed ? null : Border.all(color: Mod.divider, width: 2),
                  ),
                  child: allowed
                      ? const Icon(Icons.check, size: 18, color: Mod.bg)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
