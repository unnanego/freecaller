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
      // Three different failures, three different things for the user to do:
      // there is no such account (ask to be invited), the code was rejected
      // (retype it), or we never reached the server (try again). Everything
      // that is not an explicit rejection is a connection problem and must not
      // be mislabeled — that mislabelling was the App Store 2.1 rejection.
      setState(() {
        if (!_awaitingCode && widget.auth.isUnknownAccount(e)) {
          _error = loc.activationUnknownAccount;
        } else if (widget.auth.isBadCredential(e)) {
          _error = loc.activationInvalid;
        } else {
          _error = loc.activationNetworkError;
        }
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

  /// The two steps are separate widgets with distinct keys on purpose.
  /// Rendered as the same TextField at the same position, Flutter updates the
  /// element in place — and a keyboardType change is ignored on a field that
  /// already holds focus, so the email keyboard would stay up for the code.
  /// A different key builds a new element and a fresh input connection.
  Widget _field(AppLocalizations loc) {
    if (!_awaitingCode) {
      return TextField(
        key: const ValueKey('email'),
        controller: _input,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.none,
        style: const TextStyle(fontSize: 28),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          hintText: loc.activationEmailHint,
          // The hint is a sentence, the input is not: without its own size it
          // inherits the oversized input style and runs off the field.
          hintStyle: const TextStyle(fontSize: 18, letterSpacing: 0),
        ),
      );
    }
    return TextField(
      key: const ValueKey('code'),
      controller: _input,
      // Straight to the digits-only keypad: the code is 8 digits and the
      // person typing it is usually reading it aloud off another screen.
      keyboardType: const TextInputType.numberWithOptions(signed: false, decimal: false),
      autofocus: true,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(8),
      ],
      // Sized for 8 digits, not the 6 this started with: at 40/12 the code
      // overflowed the field on a normal-width phone.
      style: const TextStyle(fontSize: 34, letterSpacing: 4),
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        hintText: loc.activationCodeHint,
        hintStyle: const TextStyle(fontSize: 18, letterSpacing: 0),
      ),
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
