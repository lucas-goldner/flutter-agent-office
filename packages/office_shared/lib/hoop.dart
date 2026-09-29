// The basketball hoop on every floor, and its ball. The office keeps who has the ball and how it
// was last thrown (see server/court.ts); every page works out the rest itself, flying and bouncing it
// the same way from that throw (simulate below), so everyone on the floor sees the same shot.
// Port of src/shared/hoop.ts.

import 'dart:math' as math;

import 'json_util.dart';
import 'layout.dart';

double _hypot(double a, double b, [double c = 0]) => math.sqrt(a * a + b * b + c * c);

/// The hoop, on the west wall between the exit door and the kitchen, facing into the room (+x).
/// `face` is the backboard's front, `rim` the middle of the ring (`r` to the middle of its tube).
abstract final class Hoop {
  static const double z = 10.1;
  static const double face = Floor.minX + 0.62;
  static const board = (width: 1.4, bottom: 2.88, top: 3.93, thick: 0.05);
  static const rim = (x: face + 0.4, y: 3.05, z: z, r: 0.25, tube: 0.018);

  /// How far the net hangs below the ring, and how wide it is at the bottom.
  static const net = (depth: 0.42, r: 0.15);

  /// The free-throw line, this far out from the backboard.
  static const double line = 4.6;
}

abstract final class Ball {
  static const double r = 0.12;

  /// Where the ball waits when nobody has it (and where it comes back to): on the floor by the hoop,
  /// on the side away from the coffee machine, so walking up to it doesn't pour you a coffee.
  static const home = (x: Hoop.face + 0.7, z: Hoop.z - 0.8);

  /// The fastest anyone throws it, in m/s.
  static const double maxSpeed = 16;
}

/// Where a throw leaves someone's hands, and how fast: what `ball.throw` sends.
typedef BallThrow = ({double x, double y, double z, double vx, double vy, double vz});

/// A throw: where the ball left someone's hands, how fast, who threw it, and how long ago (ms) as the office sent it.
class BallShot {
  const BallShot({
    required this.x,
    required this.y,
    required this.z,
    required this.vx,
    required this.vy,
    required this.vz,
    required this.by,
    required this.elapsed,
  });

  factory BallShot.fromJson(Map<String, dynamic> j) => BallShot(
    x: asDouble(j['x']),
    y: asDouble(j['y']),
    z: asDouble(j['z']),
    vx: asDouble(j['vx']),
    vy: asDouble(j['vy']),
    vz: asDouble(j['vz']),
    by: asString(j['by']),
    elapsed: asInt(j['elapsed']),
  );

  final double x, y, z, vx, vy, vz;
  final String by;
  final int elapsed;

  BallThrow get throwAt => (x: x, y: y, z: z, vx: vx, vy: vy, vz: vz);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'z': z, 'vx': vx, 'vy': vy, 'vz': vz, 'by': by, 'elapsed': elapsed};
}

/// The ball on a floor: in someone's hands (`holder`, a PeerInfo id), or loose where `shot` left it
/// (flying, bouncing or lying still by now), or neither: waiting under the hoop.
class BallState {
  const BallState({this.holder, this.shot});

  factory BallState.fromJson(Map<String, dynamic> j) => BallState(
    holder: asStringOrNull(j['holder']),
    shot: j['shot'] is Map ? BallShot.fromJson(asMap(j['shot'])) : null,
  );

  final String? holder;
  final BallShot? shot;

  Map<String, dynamic> toJson() => {'holder': ?holder, 'shot': ?shot?.toJson()};
}

/// Whether a throw from the page is one the office passes on: from somewhere on the floor, no faster than anyone throws.
bool throwOk(BallThrow s) {
  final n = [s.x, s.y, s.z, s.vx, s.vy, s.vz];
  if (!n.every((v) => v.isFinite)) return false;
  if (_hypot(s.vx, s.vy, s.vz) > Ball.maxSpeed + 1e-6) return false;
  return _inBounds(s.x, s.y, s.z, 1);
}

/// Inside the office (or out on the balcony), under the ceiling, give or take [slack] meters.
bool _inBounds(double x, double y, double z, [double slack = 0]) {
  if (y < -0.5 - slack || y > wallHeight + slack) return false;
  final room = x > Floor.minX - slack && x < Floor.maxX + slack && z > Floor.minZ - slack && z < Floor.maxZ + slack;
  final balcony =
      x > Balcony.minX - slack && x < Balcony.maxX + slack && z > Balcony.minZ - 1 - slack && z < Balcony.maxZ + slack;
  return room || balcony;
}

// ---- Flying it --------------------------------------------------------------------------------------

/// Something solid the ball bounces off: a box from `bottom` (0 if missing) to `top`. The office's colliders are these.
class Solid {
  const Solid({
    required this.minX,
    required this.maxX,
    required this.minZ,
    required this.maxZ,
    required this.top,
    this.bottom,
    this.board = false,
  });

  final double minX, maxX, minZ, maxZ, top;
  final double? bottom;

  /// The backboard, which the ball bounces off harder and which makes a bank shot.
  final bool board;
}

enum BallHitKind { bounce, rim, board, score }

/// What the ball hit on a step, for the sounds and the net. `speed` is how hard, in m/s.
class BallHit {
  const BallHit(this.kind, this.speed);
  final BallHitKind kind;
  final double speed;
}

/// The ball in flight, as [simulate] steps it along.
class BallSim {
  BallSim({required this.x, required this.y, required this.z, required this.vx, required this.vy, required this.vz});

  double x, y, z, vx, vy, vz;

  /// Seconds since it was let go of.
  double t = 0;

  /// Lying still: nothing moves it any more.
  bool still = false;

  /// It fell through the ceiling of the floor below (or out of the building): back under the hoop it goes.
  bool lost = false;

  /// It went in (at most once a throw), and what it touched on the way: the rim, the backboard.
  bool scored = false;
  bool touchedRim = false;
  bool touchedBoard = false;

  /// It came up through the ring from underneath, which doesn't count when it drops back through.
  bool under = false;
}

/// Steps a second is cut into (`STEP` in the TS): every page cuts it the same way, so every page sees the same bounces.
const double ballStep = 1 / 120;
const double _gravity = 9.8;

/// How long a throw can bounce about before it's let lie wherever it is.
const double _maxTime = 25;

/// The part of the speed into a surface the ball keeps, bouncing back off it.
const _bounce = (floor: 0.7, rim: 0.55, board: 0.62, other: 0.58);

/// The ball just let go of (`launch` in the TS).
BallSim launchBall(BallThrow s) => BallSim(x: s.x, y: s.y, z: s.z, vx: s.vx, vy: s.vy, vz: s.vz);

/// The solids near enough to the floor for the ball to reach; the rest of the building (the street, other floors) can't be.
List<Solid> nearSolids(Iterable<Solid> all) => [
  for (final c in all)
    if (c.maxX > Floor.minX - 2 &&
        c.minX < Floor.maxX + 2 &&
        c.maxZ > Floor.minZ - 2 &&
        c.minZ < Balcony.maxZ + 2 &&
        c.top > -1 &&
        (c.bottom ?? 0) < wallHeight + 1)
      c,
];

/// The backboard, as the ball meets it (the office's colliders have it too, for walking into).
Solid backboard() {
  const b = Hoop.board;
  return Solid(
    minX: Hoop.face - b.thick,
    maxX: Hoop.face,
    minZ: Hoop.z - b.width / 2,
    maxZ: Hoop.z + b.width / 2,
    bottom: b.bottom,
    top: b.top,
    board: true,
  );
}

/// Moves the ball on by one [ballStep], bouncing it off [solids] and the rim. Hits go in [hits], if given.
/// (`step` in the TS; its `STEP` is [ballStep].)
void stepBall(BallSim s, List<Solid> solids, [List<BallHit>? hits]) {
  if (s.still || s.lost) return;
  final y0 = s.y;
  // Exactly as it falls (not a step behind), so a throw at idealSpeed goes where it should.
  s.x += s.vx * ballStep;
  s.y += s.vy * ballStep - 0.5 * _gravity * ballStep * ballStep;
  s.z += s.vz * ballStep;
  s.vy -= _gravity * ballStep;
  s.t += ballStep;

  // Through the ring? Its middle has to cross the rim's height inside it, on the way down.
  const rim = Hoop.rim;
  final off = _hypot(s.x - rim.x, s.z - rim.z);
  if (off < rim.r - 0.03) {
    if (y0 >= rim.y && s.y < rim.y && !s.under && !s.scored) {
      s.scored = true;
      hits?.add(BallHit(BallHitKind.score, -s.vy));
      // The net catches it and lets it drop.
      s.vx *= 0.3;
      s.vz *= 0.3;
      s.vy *= 0.55;
    } else if (y0 < rim.y && s.y >= rim.y) {
      s.under = true;
    }
  }
  // In the net it's steered down its middle.
  if (s.scored && s.y < rim.y && s.y > rim.y - Hoop.net.depth && off < rim.r) {
    s.vx += (rim.x - s.x) * 30 * ballStep;
    s.vz += (rim.z - s.z) * 30 * ballStep;
  }

  _hitRim(s, hits);
  var grounded = false;
  for (final c in solids) {
    final up = _hitBox(s, c, hits);
    if (up) grounded = true;
  }
  if (grounded) {
    // Rolling along the floor (or a desk) it slows down, and stops.
    final k = math.max(0.0, 1 - 1.8 * ballStep);
    s.vx *= k;
    s.vz *= k;
    if (_hypot(s.vx, s.vz) < 0.06 && s.vy.abs() < 0.3) {
      s.vx = s.vy = s.vz = 0;
      s.still = true;
    }
  }
  if (s.t > _maxTime) s.still = true;
  if (!_inBounds(s.x, s.y, s.z, 0.5)) s.lost = true;
}

/// Bounces the ball off the ring: a hoop of tube round the rim's middle.
void _hitRim(BallSim s, List<BallHit>? hits) {
  const rim = Hoop.rim;
  final dx0 = s.x - rim.x;
  final dz0 = s.z - rim.z;
  final h = _hypot(dx0, dz0);
  // The nearest point of the ring.
  final kx = h > 1e-9 ? rim.x + (dx0 / h) * rim.r : rim.x + rim.r;
  final kz = h > 1e-9 ? rim.z + (dz0 / h) * rim.r : rim.z;
  final dx = s.x - kx;
  final dy = s.y - rim.y;
  final dz = s.z - kz;
  final d = _hypot(dx, dy, dz);
  final min = Ball.r + rim.tube;
  if (d >= min || d < 1e-9) return;
  final nx = dx / d;
  final ny = dy / d;
  final nz = dz / d;
  s.x += nx * (min - d);
  s.y += ny * (min - d);
  s.z += nz * (min - d);
  final speed = _bounceOff(s, nx, ny, nz, _bounce.rim);
  if (speed > 0) {
    s.touchedRim = true;
    hits?.add(BallHit(BallHitKind.rim, speed));
  }
}

/// Bounces the ball off a box. True when it's resting on its top (or rolling along it).
bool _hitBox(BallSim s, Solid c, List<BallHit>? hits) {
  const r = Ball.r;
  final minY = c.bottom ?? 0;
  if (s.x < c.minX - r ||
      s.x > c.maxX + r ||
      s.z < c.minZ - r ||
      s.z > c.maxZ + r ||
      s.y < minY - r ||
      s.y > c.top + r) {
    return false;
  }
  final cx = math.min(math.max(s.x, c.minX), c.maxX);
  final cy = math.min(math.max(s.y, minY), c.top);
  final cz = math.min(math.max(s.z, c.minZ), c.maxZ);
  var nx = s.x - cx;
  var ny = s.y - cy;
  var nz = s.z - cz;
  final d2 = nx * nx + ny * ny + nz * nz;
  double depth;
  if (d2 >= r * r) return false;
  if (d2 > 1e-12) {
    final d = math.sqrt(d2);
    nx /= d;
    ny /= d;
    nz /= d;
    depth = r - d;
  } else {
    // Its middle got inside: out through the nearest face.
    final faces = <(double, double, double, double)>[
      (s.x - c.minX, -1, 0, 0),
      (c.maxX - s.x, 1, 0, 0),
      (s.y - minY, 0, -1, 0),
      (c.top - s.y, 0, 1, 0),
      (s.z - c.minZ, 0, 0, -1),
      (c.maxZ - s.z, 0, 0, 1),
    ];
    var best = faces[0];
    for (final f in faces) {
      if (f.$1 < best.$1) best = f;
    }
    (_, nx, ny, nz) = best;
    depth = best.$1 + r;
  }
  s.x += nx * depth;
  s.y += ny * depth;
  s.z += nz * depth;
  final board = c.board;
  final speed = _bounceOff(s, nx, ny, nz, board ? _bounce.board : (ny > 0.7 ? _bounce.floor : _bounce.other));
  if (speed > 0.25) {
    if (board) s.touchedBoard = true;
    hits?.add(BallHit(board ? BallHitKind.board : BallHitKind.bounce, speed));
  }
  return ny > 0.7;
}

/// Sends the ball back off a surface facing (nx, ny, nz): returns how fast it was going into it.
double _bounceOff(BallSim s, double nx, double ny, double nz, double keep) {
  final vn = s.vx * nx + s.vy * ny + s.vz * nz;
  if (vn >= 0) return 0;
  // Barely moving into it (rolling along, or coming to rest), it doesn't bounce at all: it settles.
  final soft = -vn < 0.5;
  final e = soft ? 0.0 : keep;
  // A little grip along the surface when it lands (rolling slows down by itself, see stepBall).
  final grip = soft ? 0.0 : 0.15;
  final tx = s.vx - vn * nx;
  final ty = s.vy - vn * ny;
  final tz = s.vz - vn * nz;
  s.vx = tx * (1 - grip) - e * vn * nx;
  s.vy = ty * (1 - grip) - e * vn * ny;
  s.vz = tz * (1 - grip) - e * vn * nz;
  return -vn;
}

/// Steps a throw on until [seconds] after it was let go of (or it's lying still).
void simulate(BallSim s, double seconds, List<Solid> solids, [List<BallHit>? hits]) {
  while (s.t + ballStep <= seconds && !s.still && !s.lost) {
    stepBall(s, solids, hits);
  }
}

/// Where a ball lying still can't be picked up from: too high up (on the whiteboard, or the loft's
/// roof), unless it's up in the loft. It goes back under the hoop, and so does a lost one.
bool outOfReach(double x, double y, double z) {
  final by = y - Ball.r;
  final inLoft = x > Loft.minX && x < Loft.maxX && z > Loft.minZ && z < Loft.maxZ;
  if (inLoft && by > Loft.y - 0.1 && by < Loft.y + 1.3) return false;
  return by > 2.3;
}

/// How long (seconds) after it stops somewhere out of reach (or goes missing) the ball turns up back under the hoop.
const double returnAfter = 3;

// ---- Shooting ---------------------------------------------------------------------------------------

/// How fast to throw from [from], [pitch] radians up from level, to drop through the middle of the
/// ring: null if no speed does it at that angle (or it's too far to throw).
double? idealSpeed(({double x, double y, double z}) from, double pitch) {
  final dx = _hypot(Hoop.rim.x - from.x, Hoop.rim.z - from.z);
  final dy = Hoop.rim.y - from.y;
  final c = math.cos(pitch);
  final lift = dx * math.tan(pitch) - dy;
  if (c <= 0 || lift <= 0) return null;
  final v = math.sqrt((_gravity * dx * dx) / (2 * c * c * lift));
  return v <= Ball.maxSpeed ? v : null;
}

/// How steeply to throw, looking [look] radians up from level: level ahead is 45° up, and looking
/// straight at the rim is the angle that drops the ball into it at 45°, steep enough to clear the
/// front of the ring.
double throwPitch(double look) =>
    math.min(1.4, math.max(-0.3, math.atan(1 + 2 * math.tan(math.min(1.2, math.max(-1.2, look))))));

/// Looking from [from] straight at the middle of the ring: how far up (radians).
double lookAtRim(({double x, double y, double z}) from) =>
    math.atan2(Hoop.rim.y - from.y, _hypot(Hoop.rim.x - from.x, Hoop.rim.z - from.z));

/// A shot at the hoop thrown at [pitch] from [from], flattened as much as it takes (and no more) for
/// its arc to stay under the office's ceiling: from far out, the steep one would hit it.
double underCeiling(({double x, double y, double z}) from, double pitch) {
  var p = pitch;
  while (p > 0.5) {
    final v = idealSpeed(from, p);
    if (v != null && from.y + math.pow(v * math.sin(p), 2) / (2 * _gravity) <= wallHeight - Ball.r - 0.3) return p;
    p -= 0.02;
  }
  return p;
}

/// Where on the wind-up meter a shot goes in (0 is a lob, 1 as hard as you throw), and how wide that sweet spot is, all told.
abstract final class Sweet {
  static const double at = 0.78;
  static const double width = 0.08;
}

/// How much slower (or faster) than the ideal a shot goes, for every whole meter it's let go of short
/// of (or past) the sweet spot. Past it the shot goes long quickly: a little late banks in off the
/// glass, and as hard as you throw (where the meter turns back, so it's easy to hit) misses.
const _sweetSlope = (short: 0.25, long: 0.8);

/// The wind-up meter goes up in this long, then back down, and so on until you let go.
const double windUp = 1.05;

/// Where the meter is [held] seconds into the wind-up: up to 1, back down to 0, up again…
double meter(double held) {
  final u = (held / windUp).remainder(2);
  return u <= 1 ? u : 2 - u;
}

/// A shot at the hoop let go of at [power] on the meter: the ideal speed for its angle, give or take how far off the sweet spot it was.
double shotSpeed(double ideal, double power) {
  final off = power - Sweet.at;
  return math.min(Ball.maxSpeed, ideal * (1 + off * (off < 0 ? _sweetSlope.short : _sweetSlope.long)));
}

/// A toss at nothing in particular: from a soft lob up to a good hard throw.
double tossSpeed(double power) => 2.5 + power * 8.5;

/// How far from the hoop (m, along the floor) a basket is worth three, as far out as the three-point line on a real court.
const double threePoint = 6.75;
