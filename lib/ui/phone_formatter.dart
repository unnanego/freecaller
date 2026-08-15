import 'package:flutter/services.dart';

/// Keeps a phone field as a single leading "+" followed by digits only, so
/// whatever the user types (extra "+", spaces, dashes, an 8-prefix habit) ends
/// up as clean E.164 — the format both the invite route and the profile's own
/// phone field are matched on.
class PlusPhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final text = '+$digits';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
