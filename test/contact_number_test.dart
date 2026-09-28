import 'package:flutter_test/flutter_test.dart';
import 'package:freecaller/data/contact_discovery.dart';

// The Israeli numbers are 54-555-…, not the tidier 54-123-…: the parser's
// metadata holds that no Israeli mobile starts 54-1, and isValid() is part of
// what is under test.
void main() {
  group('toE164', () {
    test('leaves a number that carries its own country code alone', () {
      expect(toE164('+972545551234'), '+972545551234');
      expect(toE164('+972 54-555-1234'), '+972545551234');
    });

    test('reads 00 as an international prefix', () {
      expect(toE164('00972545551234'), '+972545551234');
    });

    test("reads Russia's own 8 10 as an international prefix", () {
      expect(toE164('8 10 972 54 555 1234'), '+972545551234');
    });

    test('still reads a bare national number as Russian', () {
      expect(toE164('8 915 000 00 01'), '+79150000001');
      expect(toE164('915 000 00 01'), '+79150000001');
    });

    test("falls back to the signed-in user's own country", () {
      // An Israeli national number is not a valid Russian one.
      expect(toE164('054-555-1234'), isNull);
      expect(toE164('054-555-1234', ownE164: '+972501112233'), '+972545551234');
    });

    test('drops what is not a phone number under any reading', () {
      expect(toE164(''), isNull);
      expect(toE164('12'), isNull);
      expect(toE164('0012'), isNull);
    });
  });
}
