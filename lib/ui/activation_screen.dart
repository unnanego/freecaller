import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../services/auth_service.dart';

/// One-time sign-in, operated by a sighted helper: type the 6-digit code
/// the admin generated and tap activate. Never shown again after success.
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.signInWithCode(_code.text.trim());
      // Auth state stream rebuilds the app into the home screen.
    } catch (e) {
      setState(() {
        _error = e.toString().contains('unavailable') ||
                e.toString().contains('network')
            ? loc.activationNetworkError
            : loc.activationInvalid;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(loc.activationTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(loc.activationPrompt, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: const TextStyle(fontSize: 40, letterSpacing: 12),
              textAlign: TextAlign.center,
              decoration: InputDecoration(hintText: loc.activationHint),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 22,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 88,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const CircularProgressIndicator()
                    : Text(loc.activationSubmit, style: const TextStyle(fontSize: 28)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
