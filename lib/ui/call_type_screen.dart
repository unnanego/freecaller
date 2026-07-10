import 'package:flutter/material.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../data/models.dart';

/// Shown after tapping a contact: voice or video, Google-Meet style, as
/// three giant rows. Same tap-only, VoiceOver-first rules as the home
/// screen.
class CallTypeScreen extends StatelessWidget {
  const CallTypeScreen({
    super.key,
    required this.contact,
    required this.onStart,
    required this.onCancel,
  });

  final Contact contact;
  final void Function(Contact contact, {required bool video}) onStart;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                loc.whomToCall(contact.displayName),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            Expanded(
              child: _GiantButton(
                label: loc.voiceCall,
                color: const Color(0xFF2E7D32),
                icon: Icons.call,
                onTap: () => onStart(contact, video: false),
              ),
            ),
            Expanded(
              child: _GiantButton(
                label: loc.videoCall,
                color: const Color(0xFF1565C0),
                icon: Icons.videocam,
                onTap: () => onStart(contact, video: true),
              ),
            ),
            SizedBox(
              height: 110,
              width: double.infinity,
              child: _GiantButton(
                label: loc.cancel,
                color: const Color(0xFF455A64),
                icon: Icons.arrow_back,
                fontSize: 28,
                onTap: onCancel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GiantButton extends StatelessWidget {
  const _GiantButton({
    required this.label,
    required this.color,
    required this.icon,
    required this.onTap,
    this.fontSize = 44,
  });

  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: color,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.expand(
            child: ExcludeSemantics(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: fontSize + 12),
                  const SizedBox(width: 20),
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
