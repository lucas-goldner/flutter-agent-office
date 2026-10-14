// Port of tests/rng.test.ts.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  // The scenic loop's trees, the city round the roof, the holiday trees and the jukebox's and the DJ's
  // tunes are all laid out from these numbers: a change here moves every one of them.
  test('the seeded random gives the same numbers for the same seed, as it always has', () {
    List<double> first3(int seed) {
      final r = mulberry32(seed);
      return [r(), r(), r()];
    }

    expect(first3(0), [0.26642920868471265, 0.0003297457005828619, 0.2232720274478197]);
    expect(first3(7), [0.011704753153026104, 0.06195825757458806, 0.97690763277933]);
    expect(first3(31), [0.6722561160568148, 0.8359460374340415, 0.7496604530606419]);
    expect(first3(20260927), [0.5817536343820393, 0.3177114331629127, 0.3009456454310566]);
    expect(first3(20260929), [0.33081650477834046, 0.7369657973758876, 0.29230662784539163]);
  });

  test('the seeded random stays between 0 and 1, and two with the same seed keep in step', () {
    final a = mulberry32(12345);
    final b = mulberry32(12345);
    for (var i = 0; i < 1000; i++) {
      final x = a();
      expect(x >= 0 && x < 1, isTrue);
      expect(x, b());
    }
  });

  test('imul32 wraps like Math.imul', () {
    expect(imul32(0xffffffff, 5), 0xfffffffb);
    expect(imul32(0x45d9f3b, 0x45d9f3b), (0x45d9f3b * 0x45d9f3b) & 0xffffffff);
  });
}
