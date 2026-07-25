import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../services/auth_service.dart';

/// One-time sign-in, operated by a sighted helper. Never shown again after
/// success.
///
/// Two steps, because the credential arrives out of band: type the account's
/// email address, then the code that lands in its inbox. For the helper this is
/// the same job as before — read a code, type it in — one step later.
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _input = TextEditingController();
  String? _error;
  bool _busy = false;

  /// Set once a code has been emailed; also what switches the screen to step 2.
  String? _otpId;

  bool get _awaitingCode => _otpId != null;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final otpId = _otpId;
      if (otpId != null) {
        await widget.auth.signInWithCode(otpId, _input.text);
        // Auth state stream rebuilds the app into the home screen.
      } else {
        final id = await widget.auth.requestCode(_input.text);
        if (mounted) {
          setState(() {
            _otpId = id;
            _input.clear();
          });
        }
      }
    } catch (e) {
      // Say "invalid code" ONLY when the server explicitly rejected it;
      // everything else (offline, timeout, unavailable) is a connection problem
      // and must not be mislabeled as a bad code.
      final badCredential = widget.auth.isBadCredential(e);
      setState(() {
        _error = badCredential ? loc.activationInvalid : loc.activationNetworkError;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Back to the email field — the way out of a typo in the address, since a
  /// code for the wrong mailbox never arrives.
  void _restart() {
    setState(() {
      _otpId = null;
      _error = null;
      _input.clear();
    });
  }

  Widget _field(AppLocalizations loc) {
    if (!_awaitingCode) {
      return TextField(
        controller: _input,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.none,
        style: const TextStyle(fontSize: 28),
        textAlign: TextAlign.center,
        decoration: InputDecoration(hintText: loc.activationEmailHint),
      );
    }
    return TextField(
      controller: _input,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(8),
      ],
      style: const TextStyle(fontSize: 40, letterSpacing: 12),
      textAlign: TextAlign.center,
      decoration: InputDecoration(hintText: loc.activationCodeHint),
    );
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
            Text(
              _awaitingCode ? loc.activationCodePrompt : loc.activationEmailPrompt,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            _field(loc),
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
                    : Text(
                        _awaitingCode ? loc.activationSubmit : loc.activationEmailSubmit,
                        style: const TextStyle(fontSize: 28),
                      ),
              ),
            ),
            if (_awaitingCode) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: _busy ? null : _restart,
                child: Text(loc.activationChangeEmail,
                    style: const TextStyle(fontSize: 20)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
