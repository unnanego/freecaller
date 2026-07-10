import 'dart:developer' as developer;

void log(String message, {Object? error}) {
  developer.log(message, name: 'freecaller', error: error);
}
