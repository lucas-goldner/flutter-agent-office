// The city round the roof: laid out the same every time, and as tall as leaves the view over it.
import 'dart:math' as math;

import 'package:agent_office/world/office/city.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';

void main() {
  test('the random stream is mulberry32, the same numbers every time', () {
    final a = cityRng(20260927), b = cityRng(20260927);
    final xs = [for (var i = 0; i < 20; i++) a()];
    expect([for (var i = 0; i < 20; i++) b()], xs);
    expect(xs.every((x) => x >= 0 && x < 1), isTrue);
    // mulberry32(1)'s first number, as JavaScript gives it.
    expect(cityRng(1)(), closeTo(0.6270739405881613, 1e-12));
  });

  test('lots stand round the office, off its own block, out to the radius', () {
    final lots = cityLots();
    expect(lots, isNotEmpty);
    expect(cityLots().length, lots.length);
    for (final l in lots) {
      expect(math.sqrt(l.x * l.x + l.z * l.z), lessThan(cityRadius + cityPeriod));
      // The office's block is a plaza.
      final onOffice = l.x.abs() < cityPeriod / 2 - 4 && l.z.abs() < cityPeriod / 2 - 4;
      expect(onOffice, isFalse, reason: '${l.x}, ${l.z}');
    }
  });

  test('close by they come down with the roof; the skyline stays; no taller past six floors', () {
    final six = roofDrop(6), three = roofDrop(3);
    expect(cityRise(0, six), 1);
    expect(cityRise(0, three), closeTo(three / six, 1e-9));
    expect(cityRise(1, three), closeTo(math.sqrt(three / six), 1e-9));
    expect(cityRise(2, three), 1);
    expect(cityRise(0, roofDrop(12)), 1);
  });
}
