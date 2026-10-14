// Port of tests/sun.test.ts.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

const hour = 3600000;
const day = 86400000;

/// Hours since midnight in the office's time zone.
double hourOfDay(num ms, num utcOffset) => (((ms + utcOffset * 60000) % day) + day) % day / hour;

int utc(int y, int m, int d, [int h = 0, int min = 0]) => DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

void main() {
  test('the sky goes round a whole day every hour: midnight on the hour, noon at half past', () {
    expect(skyDayMs, hour);
    for (final utcOffset in [-420, 0, 60, 330]) {
      // 2:00 in the afternoon, on the office's clock, on 29 September 2026.
      final two = utc(2026, 9, 29, 14) - utcOffset * 60000;
      expect(hourOfDay(skyTime(two, utcOffset), utcOffset), 0);
      expect(hourOfDay(skyTime(two + 15 * 60000, utcOffset), utcOffset), 6);
      expect(hourOfDay(skyTime(two + 30 * 60000, utcOffset), utcOffset), 12);
      expect(hourOfDay(skyTime(two + 45 * 60000, utcOffset), utcOffset), 18);
      // An hour on, it's back where it was.
      expect(skyTime(two + 20 * 60000 + hour, utcOffset), skyTime(two + 20 * 60000, utcOffset));
      // Still today's date, so the sun keeps the season's hours.
      expect(
        ((skyTime(two + 50 * 60000, utcOffset) + utcOffset * 60000) / day).floor(),
        ((two + utcOffset * 60000) / day).floor(),
      );
    }
  });

  test("the sky's day runs on smoothly past the office's midnight", () {
    final midnight = utc(2026, 9, 30) + 7 * hour; // midnight in Portland (UTC-7)
    final before = skyTime(midnight - 1000, -420);
    final after = skyTime(midnight, -420);
    expect(
      after > before && after - before < 30000,
      isTrue,
      reason: '${after - before} ms of sky between one second and the next',
    );
  });

  test('the sun is up at half past and down on the hour', () {
    const lat = 40.0;
    const lon = -120.0; // the middle of UTC-8, with summer time on
    final noon = utc(2026, 9, 29, 17, 30); // 10:30 in Portland, half past the hour
    expect(sunPosition(skyTime(noon, -420), lat, lon).el, greaterThan(0.5));
    expect(sunPosition(skyTime(noon - 30 * 60000, -420), lat, lon).el, lessThan(-0.5));
  });

  test('skyNow keeps the real clock when the sky does', () {
    expect(skyNow(1234567, utcOffset: 60, realTime: true), 1234567);
    expect(skyNow(1234567, utcOffset: 60), skyTime(1234567, 60));
  });
}
