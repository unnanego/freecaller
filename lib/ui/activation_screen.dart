import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:freecaller/l10n/app_localizations.dart';

import '../services/auth_service.dart';
import 'theme/modernist.dart';

/// One-time sign-in, operated by a sighted helper. Never shown again after
/// success.
///
/// Two steps, because the credential arrives out of band: type the account's
/// email address, then the code that lands in its inbox. For the helper this is
/// the same job as before — read a code, type it in — one step later.
///
/// Laid out as the handoff's "Register" screens (design_handoff_caller_app):
/// wordmark, accent step kicker, oversized title, helper line, a bordered
/// surface field, and the action pinned to the bottom edge. It was the last
/// screen still on stock Material while everything behind it is Modernist.
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

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Mod.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Mod.s6, Mod.s8, Mod.s6, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Scrolls so the field stays reachable once the keyboard is up;
              // the action below stays pinned to the bottom edge either way.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _awaitingCode ? _backLink(loc) : _wordmark(),
                      const SizedBox(height: 28),
                      Text(loc.activationStep(_awaitingCode ? 2 : 1).toUpperCase(),
                          style: Mod.kicker()),
                      const SizedBox(height: Mod.s2),
                      Text(
                        _awaitingCode
                            ? loc.activationCodePrompt
                            : loc.activationEmailPrompt,
                        style: Mod.h1(),
                      ),
                      const SizedBox(height: Mod.s3),
                      Text(
                        _awaitingCode
                            ? loc.activationCodeHint
                            : loc.activationEmailHint,
                        style: Mod.body(),
                      ),
                      const SizedBox(height: 28),
                      _field(loc),
                      if (_error != null) ...[
                        const SizedBox(height: Mod.s4),
                        _errorBlock(),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Mod.s6),
              _action(loc),
            ],
          ),
        ),
      ),
    );
  }

  /// The app's own name, not the handoff's "DIALR" — «Звонилка» is the identity
  /// the family knows it by.
  Widget _wordmark() => Text('Звонилка',
      style: Mod.h2().copyWith(fontSize: 26, letterSpacing: -0.26));

  Widget _backLink(AppLocalizations loc) {
    return Semantics(
      button: true,
      label: loc.activationChangeEmail,
      child: InkWell(
        onTap: _busy ? null : _restart,
        child: ExcludeSemantics(
          child: Padding(
            // Padded to a comfortable target: this is a small label but it is
            // the only way back out of a mistyped address.
            padding: const EdgeInsets.symmetric(vertical: Mod.s2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.chevron_left, size: 20, color: Mod.neutral700),
                const SizedBox(width: Mod.s1),
                Text(
                  loc.activationChangeEmail.toUpperCase(),
                  style: Mod.caption(color: Mod.neutral700).copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The two steps are separate widgets with distinct keys on purpose.
  /// Rendered as the same TextField at the same position, Flutter updates the
  /// element in place — and a keyboardType change is ignored on a field that
  /// already holds focus, so the email keyboard would stay up for the code.
  /// A different key builds a new element and a fresh input connection.
  Widget _field(AppLocalizations loc) {
    final decoration = BoxDecoration(
      color: Mod.surface,
      border: Border.all(color: Mod.divider, width: 2),
    );
    const inputDecoration = InputDecoration(
      isDense: true,
      border: InputBorder.none,
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 18),
    );

    if (!_awaitingCode) {
      return Container(
        decoration: decoration,
        child: TextField(
          key: const ValueKey('email'),
          controller: _input,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          // Larger than the handoff's 16px because an older helper is usually
          // the one typing, but not so large that an ordinary address scrolls
          // out of the field — being able to proofread it is the whole point,
          // since a code sent to a mistyped address never arrives.
          style: Mod.name().copyWith(fontSize: 19, fontWeight: FontWeight.w400),
          decoration: inputDecoration,
        ),
      );
    }
    return Container(
      decoration: decoration,
      child: TextField(
        key: const ValueKey('code'),
        controller: _input,
        // Straight to the digits-only keypad: the code is 8 digits and the
        // person typing it is usually reading it aloud off another screen.
        keyboardType:
            const TextInputType.numberWithOptions(signed: false, decimal: false),
        autofocus: true,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(8),
        ],
        // 34/4 is deliberate and stays: the handoff spaces its 6-digit code at
        // 0.42em, but ours is 8 digits and overflowed a normal-width phone when
        // this was tried larger.
        style: Mod.tileInitials(34).copyWith(letterSpacing: 4),
        textAlign: TextAlign.center,
        decoration: inputDecoration,
      ),
    );
  }

  /// Failures are the whole reason this screen has three distinct messages, so
  /// they get a block of their own rather than a line of red text.
  Widget _errorBlock() {
    return Container(
      width: double.infinity,
      color: Mod.surface,
      padding: const EdgeInsets.fromLTRB(Mod.s3, Mod.s3, Mod.s4, Mod.s3),
      // IntrinsicHeight so the accent rule runs the full height of the message:
      // these strings wrap to two lines and a fixed-height bar stops short.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 2, color: Mod.accent),
            const SizedBox(width: Mod.s3),
            Expanded(
              child: Text(_error!,
                  style: Mod.body(color: Mod.text).copyWith(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(AppLocalizations loc) {
    final label =
        _awaitingCode ? loc.activationSubmit : loc.activationEmailSubmit;
    return Semantics(
      button: true,
      enabled: !_busy,
      label: label,
      child: InkWell(
        onTap: _busy ? null : _submit,
        child: Container(
          color: _busy ? Mod.neutral500 : Mod.accent,
          padding: const EdgeInsets.symmetric(vertical: 20),
          alignment: Alignment.center,
          child: ExcludeSemantics(
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Mod.bg),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_awaitingCode ? Icons.check : Icons.send,
                          size: 20, color: Mod.bg),
                      const SizedBox(width: Mod.s2),
                      Text(label.toUpperCase(),
                          style: Mod.button().copyWith(fontSize: 17)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
