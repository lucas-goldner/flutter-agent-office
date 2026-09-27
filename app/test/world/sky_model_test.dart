import 'dart:math' as math;

import 'package:agent_office/shared/protocol.dart';
import 'package:agent_office/world/sky_model.dart';
import 'package:flutter_test/flutter_test.dart';

SkyState _sky({Weather weather = Weather.clear, double intensity = 0, String? city, double? temp}) =>
    SkyState(lat: 52.52, lon: 13.4, utcOffset: 120, weather: weather, intensity: intensity, city: city, temp: temp);

void main() {
  // 2026-06-21 in Berlin: noon and midnight, office time (UTC+2).
  final noon = DateTime.utc(2026, 6, 21, 10).millisecondsSinceEpoch;
  final midnight = DateTime.utc(2026, 6, 21, 22).millisecondsSinceEpoch;

  test('a clear noon is full daylight with the lamps off', () {
    final m = SkyModel(random: math.Random(1))..set(_sky());
    m.update(0.016, 0, noon);
    expect(m.daylight, 1);
    expect(m.lampsOn, 0);
    expect(m.level, closeTo(1, 1e-9));
    expect(m.moonlit, isFalse);
    expect(m.background.color.toARGB32(), 0xFFBFE3FF);
  });

  test('midnight is dark: the moon lights things and the lamps are on', () {
    final m = SkyModel(random: math.Random(1))..set(_sky());
    m.update(0.016, 0, midnight);
    expect(m.daylight, 0);
    expect(m.moonlit, isTrue);
    expect(m.lampsOn, 1);
    expect(m.starOpacity, 1);
    expect(m.officeLight.r, greaterThan(1));
  });

  test('weather eases in after the first reading, which lands at once', () {
    final m = SkyModel(random: math.Random(1))..set(_sky(weather: Weather.rain, intensity: 1));
    m.update(0.016, 0, noon);
    expect(m.rain, 1);
    expect(m.wet, 1);
    m.set(_sky());
    m.update(1, 1, noon);
    expect(m.rain, lessThan(1));
    expect(m.rain, greaterThan(0.8));
  });

  test('describeSky reads like the old one', () {
    expect(describeSky(_sky(city: 'Berlin, Germany', temp: 11), noon), '☀️ Clear · 12:00 PM office time · Berlin, Germany, 11 °C');
    expect(describeSky(_sky(), midnight), '🌙 Clear · 12:00 AM office time');
  });
}
