// Day, night and the weather: the maths of world/sky.ts, without the scene. The server says where
// the office is and what the weather is doing (server/sky.ts); from that and the clock, [SkyModel]
// works out where the sun is, how strong every light is, the sky's colour, the fog, how far the
// lamps are on, and how wet or snowy it is outside. world/sky.dart applies it to the scene.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:vector_math/vector_math.dart' as vm;

import '../shared/protocol.dart';
import '../shared/sun.dart';

const double _deg = math.pi / 180;

const _label = {
  Weather.clear: 'Clear',
  Weather.cloudy: 'Cloudy',
  Weather.rain: 'Rain',
  Weather.storm: 'Thunderstorm',
  Weather.snow: 'Snow',
  Weather.fog: 'Fog',
};
const _icon = {
  Weather.clear: '☀️',
  Weather.cloudy: '☁️',
  Weather.rain: '🌧️',
  Weather.storm: '⛈️',
  Weather.snow: '🌨️',
  Weather.fog: '🌫️',
};

/// "🌙 Clear · 9:41 PM office time · Berlin, Germany, 11 °C", for Settings.
String describeSky(SkyState s, [int? nowMs]) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final night = sunPosition(now, s.lat, s.lon).el < -4 * _deg;
  final icon = s.weather == Weather.clear && night ? '🌙' : _icon[s.weather]!;
  final t = DateTime.fromMillisecondsSinceEpoch(now + s.utcOffset * 60000, isUtc: true);
  final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final time = '$h12:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  final where = s.city != null ? ' · ${s.city}${s.temp != null ? ', ${_fmtTemp(s.temp!)} °C' : ''}' : '';
  return '$icon ${_label[s.weather]} · $time office time$where';
}

String _fmtTemp(double t) => t == t.roundToDouble() ? t.round().toString() : t.toString();

double _lerp(double a, double b, double t) => a + (b - a) * t;
double _clamp01(double x) => x.clamp(0.0, 1.0);
double smooth(double a, double b, double x) {
  final t = _clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
}

/// Eases [x] toward [to], most of the way in [secs].
double ease(double x, double to, double dt, double secs) => x + (to - x) * (1 - math.exp(-dt / secs));

/// An RGB colour in linear light, like THREE.Color (which converts hex colours from sRGB when set,
/// and does its lerps in linear).
class Rgb {
  const Rgb(this.r, this.g, this.b);
  factory Rgb.hex(int v) => Rgb(_lin(((v >> 16) & 255) / 255), _lin(((v >> 8) & 255) / 255), _lin((v & 255) / 255));

  final double r, g, b;

  Rgb lerp(Rgb o, double t) => Rgb(_lerp(r, o.r, t), _lerp(g, o.g, t), _lerp(b, o.b, t));
  Rgb scale(double k) => Rgb(r * k, g * k, b * k);

  /// Back to sRGB for Flutter (and for the toon shader's source_color parameters), clamped.
  Color get color => Color.from(alpha: 1, red: _srgb(r), green: _srgb(g), blue: _srgb(b));
  vm.Vector3 get vector => vm.Vector3(r, g, b);

  static double _lin(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  static double _srgb(double c) {
    c = _clamp01(c);
    return c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
  }
}

abstract final class SkyColors {
  static final day = Rgb.hex(0xbfe3ff);
  static final dusk = Rgb.hex(0xffb48c);
  static final night = Rgb.hex(0x0b1431);
  static final greyDay = Rgb.hex(0xaab3bf);
  static final greyNight = Rgb.hex(0x11151d);
  static final fogDay = Rgb.hex(0xd7dce2);
  // Lit from below by the town, so it still reads as fog at night.
  static final fogNight = Rgb.hex(0x3a414d);
  static final flash = Rgb.hex(0xe4e9ff);
  static final sunHigh = Rgb.hex(0xfff1d6);
  static final sunLow = Rgb.hex(0xffa566);
  static final moon = Rgb.hex(0xa9bcff);
  static final hemiSky = Rgb.hex(0xfff5e6);
  static final hemiGround = Rgb.hex(0xc9a27a);
  static final hemiSkyNight = Rgb.hex(0x4b5b90);
  static final hemiGroundNight = Rgb.hex(0x1d1b29);
  static final ambientNight = Rgb.hex(0x8797cc);
  static final white = Rgb.hex(0xffffff);
  static final office = Rgb.hex(0xfff2de);
  static final officeNight = Rgb.hex(0xffd49c);
  static final garage = Rgb.hex(0xf6f2e4);
  static final cloudGrey = Rgb.hex(0xa3abb6);
  static final rain = Rgb.hex(0xbcd0e6);
}

/// How strong the sun and the sky's light are on a clear day, which is what the lamps make up for.
const double kFullDay = 1.5 + 0.5 + 0.6 * 2.2;

/// A preview for quick checks: this hour of the office's day, or this weather, right away.
class SkyPreview {
  const SkyPreview({this.hour, this.weather, this.intensity});
  final double? hour;
  final Weather? weather;
  final double? intensity;
}

class SkyModel {
  SkyModel({math.Random? random}) : _random = random ?? math.Random() {
    final here = guessPlace();
    state = SkyState(
      lat: here.lat,
      lon: here.lon,
      utcOffset: DateTime.now().timeZoneOffset.inMinutes,
      weather: Weather.clear,
      intensity: 0,
    );
  }

  final math.Random _random;
  late SkyState state;
  SkyPreview preview = const SkyPreview();
  bool _heard = false;
  bool _snap = true;

  /// Lightning struck; its thunder should follow `delay` seconds later.
  void Function(double delay, double loud)? onThunder;

  // ---- What the scene reads, every frame ----
  /// 1 in daylight, 0 at night.
  double daylight = 1;

  /// How hard it's raining (storms too) and snowing right now, 0-1.
  double rain = 0;
  double snow = 0;

  /// How far the lamps are on, 0-1: at night, and on the darkest of days.
  double lampsOn = 0;

  /// How much light the sun and the sky give (1 on a clear day), for your hands.
  double level = 1;
  double cover = 0;
  double fog = 0;
  double storm = 0;
  double wet = 0;
  double lying = 0;
  double flash = 0;

  /// The sun's elevation and azimuth (radians), and whether the moon lights things instead.
  double sunEl = 0;
  double sunAz = 0;
  bool moonlit = false;

  /// The light that shades everything: its direction (toward the light), colour and intensity.
  final vm.Vector3 lightDir = vm.Vector3(0, 1, 0);
  Rgb lightColor = SkyColors.sunHigh;
  double lightIntensity = 2.2;
  Rgb hemiSky = SkyColors.hemiSky;
  Rgb hemiGround = SkyColors.hemiGround;
  double hemiIntensity = 1.5;
  Rgb ambientColor = SkyColors.white;
  double ambientIntensity = 0.5;

  /// Lamplight filling the office and the garage (linear colour x strength, three.js light units).
  Rgb officeLight = const Rgb(0, 0, 0);
  Rgb garageLight = const Rgb(0, 0, 0);

  /// The sky behind everything, and the fog that fades far things into it.
  Rgb background = SkyColors.day;
  double fogNear = 40;
  double fogFar = 90;
  Rgb clouds = SkyColors.white;

  /// Stars, and the sun's and moon's discs (opacity 0-1), and their colours.
  double starOpacity = 0;
  double sunDiscOpacity = 1;
  Rgb sunDiscColor = SkyColors.white;
  double moonDiscOpacity = 0;

  /// How lit rain and snow are.
  double precipLit = 1;

  final List<double> _flashes = [];
  double _nextFlash = 0;

  /// The server's word on the sky. The weather eases from one spell to the next; a new place lands at once.
  void set(SkyState s) {
    if (!_heard || s.lat != state.lat || s.lon != state.lon) _snap = true;
    state = s;
    _heard = true;
  }

  void show(SkyPreview p) {
    preview = p;
    _snap = true;
  }

  /// The office's clock (ms), or the previewed hour today.
  int now([int? wall]) {
    final t = wall ?? DateTime.now().millisecondsSinceEpoch;
    final h = preview.hour;
    if (h == null) return t;
    final off = state.utcOffset * 60000;
    final midnight = ((t + off) ~/ 86400000) * 86400000;
    return (midnight - off + h * 3600000).round();
  }

  double _rand(double a, double b) => a + _random.nextDouble() * (b - a);

  void update(double dt, double t, [int? wallMs]) {
    final s = state;
    final weather = preview.weather ?? s.weather;
    final k = preview.intensity ?? (preview.weather != null ? 0.8 : s.intensity);
    final snap = _snap;
    _snap = false;
    double step(double x, double to, double secs) => snap ? to : ease(x, to, dt, secs);

    // The weather, easing from one spell to the next.
    final wantCover = switch (weather) {
      Weather.clear => 0.0,
      Weather.cloudy => k,
      Weather.rain => 0.8 + 0.2 * k,
      Weather.storm => 1.0,
      Weather.snow => 0.85,
      Weather.fog => 0.5,
    };
    final wantRain = weather == Weather.rain ? k : weather == Weather.storm ? math.max(0.8, k) : 0.0;
    final wantSnow = weather == Weather.snow ? k : 0.0;
    final wantFog = weather == Weather.fog ? k : weather == Weather.rain ? 0.12 * k : weather == Weather.snow ? 0.3 * k : 0.0;
    cover = step(cover, wantCover, 20);
    rain = step(rain, wantRain, 12);
    snow = step(snow, wantSnow, 12);
    fog = step(fog, wantFog, 20);
    storm = step(storm, weather == Weather.storm ? 1 : 0, 10);
    // Wet ground dries off slowly; snow piles up over a few minutes and takes a while to melt.
    final raining = rain > 0.05, snowing = snow > 0.05;
    wet = snap ? (raining ? 1 : 0) : ease(wet, raining ? 1 : 0, dt, raining ? 30 : 400);
    lying = snap ? (snowing ? 1 : 0) : ease(lying, snowing ? 1 : 0, dt, snowing ? 120 : 900);

    // The sun, and how much light it and the sky give.
    final sp = sunPosition(now(wallMs), s.lat, s.lon);
    sunEl = sp.el;
    sunAz = sp.az;
    final elD = sp.el / _deg;
    final day = smooth(-8, 4, elD);
    final dusk = math.max(0.0, 1 - (elD + 1).abs() / 9) * (1 - cover);
    daylight = day;
    _lightning(t, dt);
    final sunI = 2.2 * smooth(-3, 10, elD) * (1 - 0.8 * cover) * (1 - 0.6 * fog);
    final moonI = 0.4 * smooth(-4, -12, elD) * (1 - 0.75 * cover);
    final hemiI = _lerp(0.38, 1.5 * (1 - 0.25 * cover) * (1 - 0.35 * storm), day);
    final ambI = _lerp(0.12, 0.5, day);
    hemiIntensity = hemiI + flash * 3;
    hemiSky = SkyColors.hemiSkyNight.lerp(SkyColors.hemiSky, day);
    hemiGround = SkyColors.hemiGroundNight.lerp(SkyColors.hemiGround, day);
    ambientIntensity = ambI + flash;
    ambientColor = SkyColors.ambientNight.lerp(SkyColors.white, day);
    // A cartoon sun: never so low its shadows fill the room. At night the moon lights things, from across the sky.
    moonlit = elD < -4;
    final lightEl = (moonlit ? 50 : 25 + math.max(0, elD) * 0.6) * _deg;
    final lightAz = moonlit ? sp.az + math.pi : sp.az;
    lightDir.setValues(math.cos(lightEl) * math.sin(lightAz), math.sin(lightEl), -math.cos(lightEl) * math.cos(lightAz));
    lightIntensity = moonlit ? moonI : sunI;
    lightColor = moonlit ? SkyColors.moon : SkyColors.sunLow.lerp(SkyColors.sunHigh, smooth(0, 25, elD));
    level = _clamp01((hemiI + ambI + 0.6 * (sunI + moonI)) / kFullDay);

    // Lamps come on as it gets dark: the office's and the garage's, and the ones outside.
    final need = 1 - level;
    lampsOn = smooth(0.45, 0.62, need);
    officeLight = SkyColors.office.lerp(SkyColors.officeNight, 1 - day).scale(need * 3.2);
    garageLight = SkyColors.garage.scale(need * 2);

    // The sky's colour, and the fog, which fades far things into it.
    var sky = SkyColors.night.lerp(SkyColors.day, day);
    sky = sky.lerp(SkyColors.dusk, dusk * 0.55);
    sky = sky.lerp(SkyColors.greyNight.lerp(SkyColors.greyDay, day), cover * 0.85);
    sky = sky.lerp(SkyColors.fogNight.lerp(SkyColors.fogDay, day), fog);
    sky = sky.lerp(SkyColors.flash, flash * 0.5);
    background = sky;
    final precip = math.max(rain, snow);
    fogNear = _lerp(40, 3, fog) * (1 - 0.4 * precip);
    fogFar = _lerp(90, 28, fog) * (1 - 0.3 * precip);
    clouds = SkyColors.white.lerp(SkyColors.cloudGrey, cover);

    final clear = (1 - cover) * (1 - fog);
    starOpacity = math.pow(1 - day, 2) * clear;
    sunDiscColor = SkyColors.sunLow.lerp(SkyColors.white, smooth(0, 20, elD));
    sunDiscOpacity = smooth(-3, 0, elD) * clear;
    moonDiscOpacity = smooth(2, -2, elD) * clear;
    precipLit = 0.3 + 0.7 * math.max(level, lampsOn * 0.5);
  }

  /// In a storm, now and then the sky flashes (twice, quickly) and thunder rolls in after.
  void _lightning(double t, double dt) {
    if (storm > 0.5 && t >= _nextFlash) {
      if (_nextFlash > 0) {
        _flashes.addAll([t, t + _rand(0.1, 0.25)]);
        if (_random.nextDouble() < 0.5) _flashes.add(t + _rand(0.35, 0.6));
        onThunder?.call(_rand(0.3, 3), _rand(0.5, 1));
      }
      _nextFlash = t + _rand(6, 20);
    }
    flash *= math.exp(-dt * 10);
    while (_flashes.isNotEmpty && _flashes.first <= t) {
      _flashes.removeAt(0);
      flash = math.max(flash, _rand(0.7, 1));
    }
  }
}
