// Where the sun is, for day and night outside the office. Shared: the server guesses where the
// office is, and every browser works out the sun from that and the office's clock.

import 'dart:math' as math;

const double _rad = math.pi / 180;
const int _day = 86400000;

/// How long the sky takes over a whole day and night: an hour, so you see the sun go down and come back up.
const int skyDayMs = 3600000;

/// The time of day in a sky at [ms]: the real time when it keeps the office's clock ([realTime]), else [skyTime].
num skyNow(num ms, {required num utcOffset, bool? realTime}) => realTime == true ? ms : skyTime(ms, utcOffset);

/// The time of day in the sky at [ms] (Unix time) on the office's clock, [utcOffset] minutes east of
/// UTC: it goes round a whole day every [skyDayMs], midnight on the hour and noon at half past. It
/// stays on today's date, so the sun rises and sets as early or as late as it does there this time of year.
double skyTime(num ms, num utcOffset) {
  final local = ms + utcOffset * 60000;
  final midnight = (local / _day).floor() * _day;
  final into = (((local % skyDayMs) + skyDayMs) % skyDayMs) / skyDayMs;
  return (midnight + into * _day - utcOffset * 60000).toDouble();
}

/// The sun's elevation above the horizon and its azimuth (clockwise from north, so east is +π/2),
/// both in radians, at `ms` (Unix time) seen from `lat`/`lon` in degrees. A low-precision fit
/// (good to about a degree), which is plenty for a sky.
({double el, double az}) sunPosition(num ms, double lat, double lon) {
  final d = ms / 86400000 - 10957.5; // days since noon on 1 January 2000, UTC
  final g = (357.529 + 0.98560028 * d) * _rad;
  final q = 280.459 + 0.98564736 * d;
  final l = (q + 1.915 * math.sin(g) + 0.02 * math.sin(2 * g)) * _rad;
  final e = (23.439 - 0.00000036 * d) * _rad;
  final ra = math.atan2(math.cos(e) * math.sin(l), math.cos(l));
  final dec = math.asin(math.sin(e) * math.sin(l));
  final gmst = 18.697374558 + 24.06570982441908 * d; // hours
  final h = (gmst * 15 + lon) * _rad - ra;
  final phi = lat * _rad;
  final el = math.asin(math.sin(phi) * math.sin(dec) + math.cos(phi) * math.cos(dec) * math.cos(h));
  final az = math.atan2(-math.sin(h), math.tan(dec) * math.cos(phi) - math.sin(phi) * math.cos(h));
  return (el: el, az: az);
}

/// Where a machine probably is, from its clock: the middle of its time zone (standard time, so
/// summer time doesn't move noon), at 40° north, or 34° south where the clocks go forward in January.
({double lat, double lon}) guessPlace([DateTime? now]) {
  final y = (now ?? DateTime.now()).year;
  final jan = DateTime(y, 1, 1).timeZoneOffset.inMinutes;
  final jul = DateTime(y, 7, 1).timeZoneOffset.inMinutes;
  return (lat: jan > jul ? -34.0 : 40.0, lon: (math.min(jan, jul) / 60) * 15);
}
