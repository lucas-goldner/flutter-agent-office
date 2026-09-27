import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:office_shared/shared.dart';

// The sky over the office: where it is (which sets when the sun rises and sets) and the weather.
// With --city, both follow that city's live forecast from open-meteo.com (free, no key needed).
// Without one, the office sits in the host's time zone and the weather wanders by itself, one
// spell after another, with snow only in winter. --weather pins it either way.

const _forecastMs = 15 * 60000;
const _retryMs = 2 * 60000;
const _geocode = 'https://geocoding-api.open-meteo.com/v1/search';
const _forecast = 'https://api.open-meteo.com/v1/forecast';

final _rng = Random();
double _rand(double a, double b) => a + _rng.nextDouble() * (b - a);

/// WMO weather codes, which open-meteo reports, as our weather and how hard it's coming down.
const Map<int, (Weather, double)> _wmo = {
  0: (Weather.clear, 0),
  1: (Weather.clear, 0),
  2: (Weather.cloudy, 0.4),
  3: (Weather.cloudy, 1),
  45: (Weather.fog, 0.8),
  48: (Weather.fog, 1),
  51: (Weather.rain, 0.2),
  53: (Weather.rain, 0.3),
  55: (Weather.rain, 0.4),
  56: (Weather.rain, 0.3),
  57: (Weather.rain, 0.45),
  61: (Weather.rain, 0.45),
  63: (Weather.rain, 0.7),
  65: (Weather.rain, 1),
  66: (Weather.rain, 0.5),
  67: (Weather.rain, 0.9),
  71: (Weather.snow, 0.35),
  73: (Weather.snow, 0.65),
  75: (Weather.snow, 1),
  77: (Weather.snow, 0.3),
  80: (Weather.rain, 0.5),
  81: (Weather.rain, 0.75),
  82: (Weather.rain, 1),
  85: (Weather.snow, 0.6),
  86: (Weather.snow, 1),
  95: (Weather.storm, 0.8),
  96: (Weather.storm, 1),
  99: (Weather.storm, 1),
};

typedef WeatherSpell = ({Weather weather, double intensity});

WeatherSpell fromWmo(int code) {
  final (weather, intensity) = _wmo[code] ?? (Weather.cloudy, 0.5);
  return (weather: weather, intensity: intensity);
}

class _Place {
  _Place(this.lat, this.lon, this.name);
  final double lat;
  final double lon;

  /// What to call it, e.g. "Berlin, Germany".
  final String name;
}

const List<Map<Weather, int>> _odds = [
  {Weather.clear: 30, Weather.cloudy: 25, Weather.rain: 10, Weather.storm: 0, Weather.snow: 25, Weather.fog: 10},
  {Weather.clear: 40, Weather.cloudy: 25, Weather.rain: 20, Weather.storm: 5, Weather.snow: 0, Weather.fog: 10},
  {Weather.clear: 55, Weather.cloudy: 15, Weather.rain: 15, Weather.storm: 10, Weather.snow: 0, Weather.fog: 5},
  {Weather.clear: 35, Weather.cloudy: 25, Weather.rain: 25, Weather.storm: 3, Weather.snow: 0, Weather.fog: 12},
];

/// The next spell of made-up weather: likelier to stay as it is, snow only in winter, storms in summer.
/// [month] is 0-based, like JavaScript's getMonth().
WeatherSpell wander(Weather? prev, int month, bool south) {
  final season = ((((south ? month + 6 : month) % 12) + 1) ~/ 3) % 4; // 0 winter, 1 spring, 2 summer, 3 autumn
  final w = Map.of(_odds[season]);
  if (prev != null && w[prev]! > 0) w[prev] = w[prev]! + 25;
  var r = _rng.nextDouble() * w.values.reduce((a, b) => a + b);
  var weather = Weather.clear;
  for (final e in w.entries) {
    weather = e.key;
    if ((r -= e.value) < 0) break;
  }
  return (weather: weather, intensity: weather == Weather.clear ? 0.0 : (_rand(0.35, 1) * 100).round() / 100);
}

/// Weather set with --weather, coming down fairly hard.
WeatherSpell _pinned(Weather weather) => (weather: weather, intensity: weather == Weather.clear ? 0.0 : 0.8);

Future<Object?> _getJson(String url) async {
  final client = HttpClient();
  try {
    return await () async {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('user-agent', 'agent-office');
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) throw HttpException('HTTP ${res.statusCode}');
      return jsonDecode(text);
    }().timeout(const Duration(seconds: 10), onTimeout: () => throw TimeoutException('timed out'));
  } finally {
    client.close(force: true);
  }
}

final _coords = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$');

/// "Berlin", "Paris, France", "Portland, Oregon" or "52.52,13.41". Null when there's no such place.
Future<_Place?> _locate(String city) async {
  final c = _coords.firstMatch(city);
  if (c != null) return _Place(double.parse(c[1]!), double.parse(c[2]!), city.trim());
  final parts = city.split(',').map((s) => s.trim()).toList();
  final name = parts.first;
  final where = parts.skip(1).join(' ').toLowerCase();
  final data = await _getJson('$_geocode?name=${Uri.encodeComponent(name)}&count=10&language=en&format=json');
  final results = data is Map ? data['results'] : null;
  final hits = results is List ? results.whereType<Map>().toList() : <Map>[];
  Map? hit;
  if (where.isNotEmpty) {
    for (final h in hits) {
      if ([h['country'], h['country_code'], h['admin1']].any((s) => s is String && where.contains(s.toLowerCase()))) {
        hit = h;
        break;
      }
    }
  }
  hit ??= hits.isNotEmpty ? hits.first : null;
  if (hit == null || hit['latitude'] is! num || hit['longitude'] is! num) return null;
  final label = [hit['name'], hit['country']].where((s) => s is String && s.isNotEmpty).join(', ');
  return _Place((hit['latitude'] as num).toDouble(), (hit['longitude'] as num).toDouble(), label);
}

SkyState _skyAt(({double lat, double lon}) here, int utcOffset, WeatherSpell w, {String? city, double? temp}) =>
    SkyState(
      lat: here.lat,
      lon: here.lon,
      utcOffset: utcOffset,
      weather: w.weather,
      intensity: w.intensity,
      city: city,
      temp: temp,
    );

class Sky {
  Sky({String? city, Weather? weather, required void Function(SkyState state) onChange})
    : _city = city,
      _weather = weather,
      _onChange = onChange {
    final now = DateTime.now();
    final here = guessPlace(now);
    final w = weather != null
        ? _pinned(weather)
        : city != null
        ? _pinned(Weather.clear)
        : wander(null, now.month - 1, here.lat < 0);
    state = _skyAt(here, now.timeZoneOffset.inMinutes, w);
  }

  late SkyState state;
  String? _city;
  final Weather? _weather;
  final void Function(SkyState state) _onChange;
  Timer? _timer;
  _Place? _place;

  /// Whether we've said the forecast is missing, so a flaky network doesn't flood the log.
  bool _warned = false;

  void start() {
    if (_city != null) {
      unawaited(_forecastNow());
    } else {
      _later((_rand(20, 50) * 60000).round(), _drift);
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _later(int ms, void Function() fn) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: ms), fn);
  }

  void _set(SkyState next) {
    if (jsonEncode(next.toJson()) == jsonEncode(state.toJson())) return;
    state = next;
    _onChange(next);
  }

  /// Made-up weather: a new spell every 20–50 minutes, in the host's time zone.
  void _drift() {
    final now = DateTime.now();
    final here = guessPlace(now);
    final w = _weather != null ? _pinned(_weather) : wander(state.weather, now.month - 1, here.lat < 0);
    _set(_skyAt(here, now.timeZoneOffset.inMinutes, w));
    _later((_rand(20, 50) * 60000).round(), _drift);
  }

  Future<void> _forecastNow() async {
    final city = _city!;
    try {
      _place ??= await _locate(city);
      final place = _place;
      if (place == null) {
        stderr.writeln('agent-office: couldn\'t find the city "$city"; the weather is made up instead');
        _city = null;
        return _drift();
      }
      final f = await _getJson(
        '$_forecast?latitude=${place.lat}&longitude=${place.lon}&current=temperature_2m,weather_code&timezone=auto',
      );
      final current = f is Map ? f['current'] : null;
      final code = current is Map ? current['weather_code'] : null;
      if (code is! num || !code.isFinite) throw const FormatException('no current weather in the forecast');
      final w = _weather != null ? _pinned(_weather) : fromWmo(code.toInt());
      final temp = (current as Map)['temperature_2m'];
      final off = (f as Map)['utc_offset_seconds'];
      final utcOffset = off is num && off.isFinite ? (off / 60).round() : state.utcOffset;
      _set(
        _skyAt(
          (lat: place.lat, lon: place.lon),
          utcOffset,
          w,
          city: place.name,
          temp: temp is num && temp.isFinite ? temp.round().toDouble() : null,
        ),
      );
      _warned = false;
      _later(_forecastMs, () => unawaited(_forecastNow()));
    } catch (err) {
      if (!_warned) {
        final why = err is FormatException ? err.message : (err is HttpException ? err.message : '$err');
        stderr.writeln('agent-office: no weather for $city yet ($why); trying again in a couple of minutes');
      }
      _warned = true;
      _later(_retryMs, () => unawaited(_forecastNow()));
    }
  }
}
