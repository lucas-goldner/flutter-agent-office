// Drinks from the rooftop bar: each goes to your head over a few seconds, then wears off over a
// minute or so. They add up, and the more you've had, the more the view sways, doubles and smears
// (world/drunk.dart) and the more you stagger (see PlayerController.drunk). Water helps a little.
// Times are seconds, on whichever clock the caller passes in as `now`. A port of booze.ts.

import 'dart:math' as math;

import 'package:office_shared/rooftop.dart';

/// A drink kicks in over about this long.
const double _kickIn = 4;

/// And wears off at this much a second: a beer (0.28) in about half a minute, a shot (0.6) in a minute.
const double _soberRate = 1 / 95;

/// You hold the glass for this long after it's poured, sipping.
const double glassSeconds = 45;

/// How it feels, from sober (0) up: tipsy (1), drunk (2), wasted (3).
const List<double> _stages = [0.2, 0.65, 1.15];

/// What you're told as it changes (by stage).
const List<String> feelings = [
  '😌 You feel sober again',
  '🥴 You’re feeling a little tipsy',
  '🌀 Whoa… is the city spinning?',
  '🤪 You’re wasted. Maybe have some water',
];

class Booze {
  /// In your head so far, as of [_at].
  double _level = 0;
  double _at = 0;

  /// Drunk but not felt yet: it soaks in over [_kickIn] seconds.
  double _coming = 0;
  Drink? _glass;
  double _glassUntil = 0;

  /// Drinks one: it starts to kick in, and you hold the glass for a while.
  void drink(Drink d, double now) {
    _settle(now);
    if (d.strength < 0) {
      _level = math.max(0, _level + d.strength);
    } else {
      _coming += d.strength;
    }
    _glass = d;
    _glassUntil = now + glassSeconds;
  }

  /// Had enough: the bartender pours you a water instead. Counts what's still on its way.
  bool cutOff(double now) {
    _settle(now);
    return _level + _coming >= boozeLimit;
  }

  /// How drunk you are now: 0 sober, about 0.3 tipsy, 1 properly drunk, up to [boozeLimit].
  double amount(double now) {
    _settle(now);
    return _level;
  }

  int stage(double now) {
    final a = amount(now);
    return a >= _stages[2]
        ? 3
        : a >= _stages[1]
        ? 2
        : a >= _stages[0]
        ? 1
        : 0;
  }

  /// The glass in your hand, if you're still holding one.
  Drink? holding(double now) {
    if (_glass != null && now > _glassUntil) _glass = null;
    return _glass;
  }

  /// Puts the glass down (leaving the roof: drinks stay at the bar).
  void putDown() => _glass = null;

  void _settle(double now) {
    final dt = math.max(0.0, now - _at);
    _at = now;
    if (dt == 0) return;
    final soak = _coming * (1 - math.exp((-dt * 3) / _kickIn));
    _coming = _coming - soak < 0.001 ? 0 : _coming - soak;
    _level = math.max(0, _level + soak - _soberRate * dt);
  }
}

/// How hard a drink hits, for the bar's menu.
String drinkKick(Drink d) {
  if (d.strength < 0) return '💧 sobers you up a little';
  if (d.strength == 0) return 'no alcohol';
  return d.strength >= 0.55
      ? '🌀🌀🌀 strong'
      : d.strength >= 0.4
      ? '🌀🌀 goes to your head'
      : '🌀 light';
}

/// What the bartender says as they slide it over.
const Map<DrinkId, String> cheers = {
  DrinkId.beer: 'Cheers! 🍻',
  DrinkId.wine: 'Salud!',
  DrinkId.martini: 'Shaken, not stirred',
  DrinkId.maitai: 'Aloha!',
  DrinkId.shot: 'Salt, shot, lime… whoa',
  DrinkId.mojito: 'Fresh and minty',
  DrinkId.water: 'Good call. Stay hydrated',
};
