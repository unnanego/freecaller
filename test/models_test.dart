import 'package:flutter_test/flutter_test.dart';
import 'package:freecaller/data/models.dart';

void main() {
  group('callStateFrom', () {
    test('maps every known state', () {
      for (final state in CallState.values) {
        expect(callStateFrom(state.name), state);
      }
    });

    test('unknown or null input falls back to ended (terminal, safe)', () {
      expect(callStateFrom('garbage'), CallState.ended);
      expect(callStateFrom(null), CallState.ended);
    });
  });
}
