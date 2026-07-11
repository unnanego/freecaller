import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

void log(String message, {Object? error}) {
  developer.log(message, name: 'freecaller', error: error);
  // developer.log doesn't reach logcat/console reliably; mirror to print in
  // debug so device logs show engine/LiveKit decisions.
  if (kDebugMode) {
    debugPrint('freecaller: $message${error != null ? ' | $error' : ''}');
  }
}
