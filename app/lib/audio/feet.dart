// What a footstep is made of (#269): a port of sound/feet.ts and the ground and step rules of
// sound/steps.ts, shared by the web's sound (sound_web.dart) and the native renderer (office_render.dart).
//
// A foot comes down in two parts, the heel and then the ball of the foot, and what you hear of each is the
// ground: a plank knocks, concrete ticks, grass swishes, the castle's flagstones clack and the hall
// answers. So each kind of ground has a few samples of each part, no two alike.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:office_shared/garage.dart' show pavement;
import 'package:office_shared/layout.dart' show Balcony, Floor, Road, inWing;

import 'samples.dart' show lumpy, sample;
import 'sound_model.dart' show Pos;

/// What's underfoot.
enum Ground { wood, concrete, grass, stone }

/// The two parts of a step on one kind of ground, a few of each.
typedef Footfalls = ({List<Float32List> heel, List<Float32List> toe});

/// How many of each part there are to pick from.
const int footVariants = 6;

/// How loud a footfall on each kind of ground plays, so a step is about as loud to the ear on all of them.
const Map<Ground, double> groundLevel = {
  Ground.wood: 0.34,
  Ground.concrete: 0.31,
  Ground.grass: 0.22,
  Ground.stone: 0.31,
};

/// What's underfoot where someone's feet are: the planks of the office (its loft, its balcony and the
/// roof's deck too), the flagstones of a hall on a map of its own, and down below, the concrete of the
/// garage, the lots and the street, with grass past them. [roof]: up on the roof; [hall]: on a map of its
/// own; [wing]: how far the floor's built out into the back office.
Ground groundAt(Pos feet, {bool roof = false, bool hall = false, int wing = 0}) {
  if (roof) return Ground.wood;
  if (hall) return Ground.stone;
  final x = feet.x, y = feet.y, z = feet.z;
  bool on(double minX, double maxX, double minZ, double maxZ) => x > minX && x < maxX && z > minZ && z < maxZ;
  // Up on the floor, whatever isn't the office is the landing outside its door, and the steps down from it.
  if (y > -0.5) {
    return on(Floor.minX, Floor.maxX, Floor.minZ, Floor.maxZ) ||
            on(Balcony.minX, Balcony.maxX, Balcony.minZ, Balcony.maxZ) ||
            inWing(x, z, wing)
        ? Ground.wood
        : Ground.concrete;
  }
  // The sidewalks run the length of the street, either side of the road.
  return pavement.any((b) => on(b.minX, b.maxX, b.minZ, b.maxZ)) || (z > Road.minZ - 2 && z < Road.maxZ + 2)
      ? Ground.concrete
      : Ground.grass;
}

/// One foot coming down: the heel at once, then the ball of the foot [toeAfter] seconds later, each at its
/// [level] and [rate]. Sooner and harder the faster they're going ([pace] 0 at a walk, 1 at a run).
typedef Fall = ({double heelLevel, double heelRate, double toeAfter, double toeLevel, double toeRate});

/// A foot coming down on [ground] at [pace], [gain] times as loud, at [pitch].
Fall fall(Ground ground, double pace, double gain, double pitch, math.Random rng) {
  double r(double a, double b) => a + rng.nextDouble() * (b - a);
  final level = groundLevel[ground]! * gain * r(0.8, 1.1) * (1 + 0.3 * pace);
  final rate = pitch * r(0.94, 1.06) * (1 + 0.08 * pace);
  return (
    heelLevel: level,
    heelRate: rate,
    toeAfter: r(0.045, 0.06) * (1 - 0.6 * pace),
    toeLevel: level * (0.6 + 0.3 * pace),
    toeRate: rate * r(0.97, 1.03),
  );
}

/// Covering less ground than this (m/s) since your last footstep, your feet make no sound: a walk is 4.6.
const double quietFeet = 1.2;

/// Whether a stride you just finished sounds: only for ground you've covered ([far] meters in [time]
/// seconds), so walking into a wall your feet go nowhere and make no sound.
bool stepHeard(double far, double time) => far > time * quietFeet;

/// How hard a landing is, 0 (a hop) to 1 (off the loft), from how fast you were falling (m/s, negative
/// down); null for no landing at all (stepping down a stair).
double? landing(double fallV) => fallV < -4 ? math.min(1, (-fallV - 4) / 7) : null;

/// Going faster than this (m/s), someone's running: a walk is 4.6 and a run 7.5.
const double runSpeed = 6;

/// Picks one of [xs] that isn't [last], the one picked last time.
T another<T>(List<T> xs, T? last, math.Random rng) {
  var x = xs[rng.nextInt(xs.length)];
  while (identical(x, last) && xs.length > 1) {
    x = xs[rng.nextInt(xs.length)];
  }
  return x;
}

// ---- The samples ----------------------------------------------------------------------------------

typedef _Voice = double Function(double t);

/// Noise with everything above [hz] taken off, about as loud whatever [hz] is.
double Function() _dull(int sr, double hz, math.Random rng) {
  final k = 1 - math.exp(-2 * math.pi * hz / sr);
  final norm = math.sqrt(1.5 * sr / hz);
  var a = 0.0, b = 0.0;
  return () {
    a += (rng.nextDouble() * 2 - 1 - a) * k;
    b += (a - b) * k;
    return b * norm;
  };
}

/// [src] (noise, unless it's given) with only what's round [hz] left, [q] narrow, about as loud whatever.
double Function() _band(int sr, double hz, double q, math.Random rng, [double Function()? src]) {
  final s = src ?? () => rng.nextDouble() * 2 - 1;
  final f = math.min(0.9, 2 * math.sin(math.pi * hz / sr));
  final norm = math.sqrt(sr / (q * hz));
  var low = 0.0, mid = 0.0;
  return () {
    low += f * mid;
    mid += f * (s() - low - mid / q);
    return mid * norm;
  };
}

/// Grit under a sole: [rate] grains a second, each a tick.
double Function() _grit(int sr, double hz, double rate, math.Random rng) {
  final scale = math.sqrt(sr / rate);
  return _band(sr, hz, 1.5, rng, () => rng.nextDouble() < rate / sr ? (rng.nextDouble() * 2 - 1) * scale : 0);
}

/// Something knocked: it rings at [hz] and is gone in about [ms].
_Voice _ring(double hz, double ms) =>
    (t) => math.sin(2 * math.pi * hz * t) * math.exp(-t * 1000 / ms);

/// The shape of a blow: up in [rise] ms, then dying away over [fall] ms.
double _hit(double t, double rise, double fall) =>
    t <= 0 ? 0 : math.min(1, t * 1000 / rise) * math.exp(-t * 1000 / fall);

typedef _Recipe = ({
  double seconds,
  _Voice Function(int sr, math.Random rng) heel,
  _Voice Function(int sr, math.Random rng) toe,
});

double _r(math.Random rng, double a, double b) => a + rng.nextDouble() * (b - a);

final Map<Ground, _Recipe> _recipes = {
  // A shoe on the office's planks: the heel's tick, the board it lands on knocking, and the floor's
  // thump under it; then the sole slapping down, with no weight behind it.
  Ground.wood: (
    seconds: 0.16,
    heel: (sr, rng) {
      final tick = _band(sr, _r(rng, 1900, 2500), 1.2, rng);
      final thump = _dull(sr, 450, rng);
      final f = _r(rng, 150, 195);
      final board = [_ring(f, 18), _ring(f * _r(rng, 2.1, 2.5), 12), _ring(f * _r(rng, 4.3, 5.2), 7)];
      return (t) =>
          tick() * _hit(t, 0.3, 3) * 0.6 +
          thump() * _hit(t, 1.5, 14) * 0.7 +
          board[0](t) * 0.8 +
          board[1](t) * 0.6 +
          board[2](t) * 0.45;
    },
    toe: (sr, rng) {
      final slap = _band(sr, _r(rng, 1100, 1500), 0.9, rng);
      final thump = _dull(sr, 650, rng);
      final board = _ring(_r(rng, 240, 310), 11);
      return (t) => slap() * _hit(t, 1, 8) * 0.6 + thump() * _hit(t, 2, 11) * 0.5 + board(t) * 0.5;
    },
  ),
  // Concrete and asphalt, in the garage and down on the street: nothing rings, so it's a hard tick, a
  // short dead thud and the grit under the sole.
  Ground.concrete: (
    seconds: 0.14,
    heel: (sr, rng) {
      final tick = _band(sr, _r(rng, 2200, 3000), 0.8, rng);
      final thud = _dull(sr, 700, rng);
      final under = _ring(_r(rng, 95, 120), 10);
      final grains = _grit(sr, _r(rng, 3600, 4400), 1400, rng);
      return (t) =>
          tick() * _hit(t, 0.2, 2.5) * 0.5 +
          thud() * _hit(t, 1, 10) * 0.7 +
          under(t) * 0.3 +
          grains() * _hit(t, 4, 20) * 0.12;
    },
    toe: (sr, rng) {
      final slap = _band(sr, _r(rng, 1900, 2600), 0.9, rng);
      final thud = _dull(sr, 600, rng);
      final grains = _grit(sr, _r(rng, 3400, 4600), 1800, rng);
      return (t) => slap() * _hit(t, 0.8, 6) * 0.45 + thud() * _hit(t, 1.5, 9) * 0.6 + grains() * _hit(t, 6, 28) * 0.2;
    },
  ),
  // Grass, past the pavement: no tick at all, a soft thump in the turf and the blades swishing round the
  // shoe, unevenly.
  Ground.grass: (
    seconds: 0.26,
    heel: (sr, rng) {
      final thump = _dull(sr, 300, rng);
      final swish = _band(sr, _r(rng, 1800, 2600), 0.9, rng);
      final blades = lumpy(sr, 0.004, 0.012, rng);
      return (t) => thump() * _hit(t, 5, 26) * 0.7 + swish() * (0.25 + blades()) * _hit(t, 9, 30) * 0.5;
    },
    toe: (sr, rng) {
      final thump = _dull(sr, 420, rng);
      final swish = _band(sr, _r(rng, 2200, 3200), 0.9, rng);
      final blades = lumpy(sr, 0.004, 0.012, rng);
      return (t) => thump() * _hit(t, 6, 20) * 0.4 + swish() * (0.25 + blades()) * _hit(t, 14, 45) * 0.4;
    },
  ),
  // The castle's flagstones: a hard clack, and the hall saying it back for a moment after.
  Ground.stone: (
    seconds: 0.5,
    heel: (sr, rng) {
      final tick = _band(sr, _r(rng, 1700, 2300), 1.4, rng);
      final thud = _dull(sr, 300, rng);
      final f = _r(rng, 520, 680);
      final flag = [_ring(f, 9), _ring(f * _r(rng, 2, 2.4), 5)];
      final hall = _band(sr, _r(rng, 600, 900), 0.6, rng, _dull(sr, 2200, rng));
      // The blow itself is over in a tenth of a second: after that there's only the hall to work out.
      double blow(double t) => t > 0.1
          ? 0
          : tick() * _hit(t, 0.2, 3) * 0.5 + thud() * _hit(t, 1, 12) * 0.5 + flag[0](t) * 0.6 + flag[1](t) * 0.3;
      return (t) => blow(t) + hall() * _hit(t - 0.018, 12, 150) * 0.016;
    },
    toe: (sr, rng) {
      final slap = _band(sr, _r(rng, 1500, 2000), 1, rng);
      final thud = _dull(sr, 520, rng);
      final hall = _band(sr, _r(rng, 700, 1100), 0.6, rng, _dull(sr, 2200, rng));
      double blow(double t) => t > 0.1 ? 0 : slap() * _hit(t, 0.8, 7) * 0.5 + thud() * _hit(t, 1.5, 9) * 0.4;
      return (t) => blow(t) + hall() * _hit(t - 0.018, 12, 130) * 0.014;
    },
  ),
};

/// The samples of a step on [ground] at [sr]: [footVariants] of the heel and of the ball of the foot.
Footfalls footfalls(int sr, Ground ground, math.Random rng) {
  final r = _recipes[ground]!;
  final fade = r.seconds * 0.2;
  // Faded out at its end, so a sample that's still ringing doesn't stop with a click.
  Float32List made(_Voice voice) => sample(sr, r.seconds, (t) => voice(t) * math.min(1, (r.seconds - t) / fade), 0.9);
  List<Float32List> each(_Voice Function(int, math.Random) part) => [
    for (var i = 0; i < footVariants; i++) made(part(sr, rng)),
  ];
  return (heel: each(r.heel), toe: each(r.toe));
}
