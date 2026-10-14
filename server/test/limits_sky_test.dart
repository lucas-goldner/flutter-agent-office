import 'dart:io';

import 'package:agent_office_server/src/limits.dart';
import 'package:agent_office_server/src/sky.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('plan limits: windows, per-model weeks, and no plan', () {
    final r = PlanLimitsReader(null, const {}, () => true, (_) {});
    final l = r.parse({
      'subscription_type': 'max',
      'rate_limits': {
        'five_hour': {'utilization': 12.5, 'resets_at': '2026-01-01T00:00:00Z'},
        'seven_day': {'utilization': 140},
        'model_scoped': [
          {'display_name': ' Opus ', 'utilization': 3},
          {'display_name': '', 'utilization': 3},
          {'display_name': 'Broken'},
        ],
      },
    });
    expect(l.plan, 'max');
    expect([for (final w in l.windows) w.label], ['5h session', 'Week', 'Opus week']);
    expect(l.windows[0].resetsAt, DateTime.utc(2026).millisecondsSinceEpoch);
    expect(l.windows[1].pct, 100);
    // An answer without per-model buckets keeps the last ones.
    expect(
      r
          .parse({
            'rate_limits': {
              'five_hour': {'utilization': 1},
            },
          })
          .windows
          .map((w) => w.label),
      ['5h session', 'Opus week'],
    );
    expect(r.parse({'rate_limits_available': false, 'rate_limits': {}}).windows, isEmpty);
    expect(r.parse(null).windows, isEmpty);
  });

  test('sky: WMO codes and made-up weather', () {
    expect(fromWmo(63), (weather: Weather.rain, intensity: 0.7));
    expect(fromWmo(1234), (weather: Weather.cloudy, intensity: 0.5));
    for (var i = 0; i < 200; i++) {
      expect(wander(null, 6, false).weather, isNot(Weather.snow), reason: 'no snow in a northern July');
      expect(wander(null, 0, true).weather, isNot(Weather.snow), reason: 'no snow in a southern January');
      final w = wander(Weather.rain, 0, false);
      expect(w.intensity, w.weather == Weather.clear ? 0 : inInclusiveRange(0.35, 1));
    }
  });

  test('the sky keeps the clock someone picked, and keeps it across a restart', () {
    final dir = Directory.systemTemp.createTempSync('sky-clock-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final clockFile = '${dir.path}/sky-clock.json';
    final heard = <bool>[];
    final sky = Sky(weather: Weather.clear, clockFile: clockFile, onChange: (s) => heard.add(s.realTime ?? false));
    expect(sky.state.realTime, isNull);
    sky.setClock(true);
    expect(sky.state.realTime, isTrue);
    expect(heard, [true]);
    // After a restart the pick wins over the command line.
    expect(Sky(weather: Weather.clear, clockFile: clockFile, onChange: (_) {}).state.realTime, isTrue);
    sky.setClock(false);
    expect(sky.state.realTime, isNull);
    expect(Sky(weather: Weather.clear, realTime: true, clockFile: clockFile, onChange: (_) {}).state.realTime, isNull);
  });

  test('a city starts where the last forecast put it', () {
    final dir = Directory.systemTemp.createTempSync('sky-place-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final placeFile = '${dir.path}/sky-place.json';
    File(
      placeFile,
    ).writeAsStringSync('{"city":"Berlin","lat":52.52,"lon":13.41,"name":"Berlin, Germany","utcOffset":120}');
    final s = Sky(city: 'Berlin', placeFile: placeFile, onChange: (_) {}).state;
    expect((s.lat, s.lon, s.utcOffset, s.city), (52.52, 13.41, 120, 'Berlin, Germany'));
    expect(Sky(city: 'Paris', placeFile: placeFile, onChange: (_) {}).state.city, isNull);
  });
}
