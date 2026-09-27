// Where the sun is, for day and night outside the office. Shared: the server guesses where the
// office is, and every browser works out the sun from that and its own clock.

import 'dart:math' as math;

const double _rad = math.pi / 180;

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
