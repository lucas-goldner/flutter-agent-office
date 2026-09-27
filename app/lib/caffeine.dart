// Coffee from the kitchen machine: a minute of quicker walking and higher jumps. Keep drinking
// before the last cup wears off and you get the jitters for a few seconds.
// Times are seconds, on whichever clock the caller passes in as `now`.

import 'dart:math' as math;

/// How long one cup keeps you going.
const double buzzSeconds = 60;

/// Walking and running speed while buzzed, as a multiple of normal.
const double _speed = 1.4;

/// Jump speed while buzzed: about 45% higher jumps.
const double _jump = 1.2;

/// The boost eases off over the last few seconds instead of stopping dead.
const double _fadeSeconds = 4;

/// The cup in a row that brings on the jitters.
const int _jitteryCup = 3;
const double _jitterSeconds = 4;

class Caffeine {
  /// When the current buzz wears off.
  double _until = 0;
  double _jitterUntil = 0;

  /// Cups in a row, each drunk before the one before it wore off.
  int cups = 0;

  /// Drinks a cup, which tops the buzz back up to a full minute. Returns whether it brought on the jitters.
  bool drink(double now) {
    cups = buzzed(now) ? cups + 1 : 1;
    _until = now + buzzSeconds;
    if (cups < _jitteryCup) return false;
    _jitterUntil = now + _jitterSeconds;
    return true;
  }

  bool buzzed(double now) => now < _until;

  /// Seconds of buzz left.
  double left(double now) => math.max(0, _until - now);

  /// Walking and running speed, as a multiple of normal.
  double speed(double now) => 1 + (_speed - 1) * _strength(now);

  /// Jump speed, as a multiple of normal.
  double jump(double now) => 1 + (_jump - 1) * _strength(now);

  /// 0 (steady) to 1 (the jitters), settling down over the last second.
  double jitter(double now) => math.min(1, math.max(0, _jitterUntil - now));

  double _strength(double now) => math.min(1, left(now) / _fadeSeconds);
}
