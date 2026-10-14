import 'dart:math' as math;

import 'package:office_shared/protocol.dart';
import 'package:agent_office/world/sky_model.dart';
import 'package:flutter_test/flutter_test.dart';

// On the real clock (--real-time-sky), unless [realTime] is false: a whole day every hour.
SkyState _sky({
  Weather weather = Weather.clear,
  double intensity = 0,
  String? city,
  double? temp,
  bool realTime = true,
}) => SkyState(
  lat: 52.52,
  lon: 13.4,
  utcOffset: 120,
  weather: weather,
  intensity: intensity,
  city: city,
  temp: temp,
  realTime: realTime ? true : null,
);

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
    expect(
      describeSky(_sky(city: 'Berlin, Germany', temp: 11), noon),
      '☀️ Clear · 12:00 PM outside · Berlin, Germany, 11 °C',
    );
    expect(describeSky(_sky(), midnight), '🌙 Clear · 12:00 AM outside');
  });

  group('a whole day and night every hour (#194)', () {
    test('noon at half past, midnight on the hour, by the office clock', () {
      final m = SkyModel(random: math.Random(1), clock: () => noon + 30 * 60000)..set(_sky(realTime: false));
      m.update(0.016, 0);
      expect(m.daylight, 1);
      final dark = SkyModel(random: math.Random(1), clock: () => noon)..set(_sky(realTime: false));
      dark.update(0.016, 0);
      expect(dark.daylight, 0);
      expect(dark.lampsOn, 1);
    });

    test('Settings says the time of day in the sky', () {
      expect(describeSky(_sky(realTime: false), noon + 30 * 60000), '☀️ Clear · 12:00 PM outside');
      expect(describeSky(_sky(realTime: false), noon + 45 * 60000), contains('6:00 PM outside'));
      expect(describeSky(_sky(), noon + 45 * 60000), contains('12:45 PM outside'));
    });

    test('the note says which clock it keeps', () {
      expect(outsideNote(real: true, live: true), contains('the real time of day'));
      expect(outsideNote(real: false, live: false), contains('a whole day and night every hour'));
      expect(outsideNote(real: false, live: false), contains('--city'));
    });
  });
}
