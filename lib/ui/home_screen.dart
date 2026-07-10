import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/models.dart';

/// The whole home screen is contacts: each one a giant full-width button
/// filling an equal share of the screen. Tap-only, VoiceOver-first.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.contacts,
    required this.missedFrom,
    required this.onCall,
  });

  final List<Contact> contacts;

  /// Most recent unseen missed-call peer, if any — shown as a callback banner.
  final Contact? missedFrom;
  final void Function(Contact contact) onCall;

  static const _palette = [
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFF6A1B9A),
    Color(0xFFEF6C00),
  ];

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    if (contacts.isEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              loc.homeNoContacts,
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (missedFrom != null)
              Semantics(
                button: true,
                label: '${loc.missedCallFrom(missedFrom!.displayName)}. '
                    '${loc.callContact(missedFrom!.displayName)}',
                child: Material(
                  color: const Color(0xFFB71C1C),
                  child: InkWell(
                    onTap: () => onCall(missedFrom!),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      child: ExcludeSemantics(
                        child: Text(
                          loc.missedCallFrom(missedFrom!.displayName),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            for (final (i, contact) in contacts.indexed)
              Expanded(
                child: _ContactButton(
                  contact: contact,
                  color: _palette[i % _palette.length],
                  onCall: onCall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ContactButton extends StatelessWidget {
  const _ContactButton({
    required this.contact,
    required this.color,
    required this.onCall,
  });

  final Contact contact;
  final Color color;
  final void Function(Contact contact) onCall;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Semantics(
      button: true,
      label: loc.callContact(contact.displayName),
      child: Material(
        color: color,
        child: InkWell(
          onTap: () => onCall(contact),
          child: SizedBox.expand(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                // The visible name is decoration; VoiceOver reads the
                // Semantics label above («Позвонить …») exactly once.
                child: ExcludeSemantics(
                  child: Text(
                    contact.displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 56,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
