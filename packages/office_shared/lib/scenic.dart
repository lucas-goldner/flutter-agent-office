// The scenic loop: a country road out of either end of the street that goes the long way round and
// back. Out of town to the east it passes a farm, turns south into the pines, then runs west along
// the foot of the mountains (through a tunnel under a spur of them), turns north up the coast past
// the beach and comes back into town from the west. The street in front of the office is the rest
// of the loop. Cars can drive all of it (see [paved] in garage.dart). It's all laid out here, as
// numbers, so the office and the tests agree on it.
// Ported from src/shared/scenic.ts.

import 'dart:math' as math;

import 'json_util.dart';
import 'layout.dart';

/// Where the street stops and the loop takes over, either way along it (x).
const double streetEnd = 110;

/// The middle of the street, which the loop leaves from and comes back to.
const double streetZ = (Road.minZ + Road.maxZ) / 2;

/// The loop's asphalt either side of its middle (as wide as the street's).
const double loopHalf = (Road.maxZ - Road.minZ) / 2;

/// How far from its middle a car can go: onto the gravel shoulder, a little.
const double loopPaved = loopHalf + 0.7;

/// The bits of the loop, in the order you drive them (east out of town, round, back from the west).
enum ScenicPlace implements WireEnum {
  farm('farm', 'Meadowbrook Farm', '🌾'),
  forest('forest', 'Whispering Pines', '🌲'),
  mountains('mountains', 'Summit Pass', '🏔️'),
  tunnel('tunnel', 'Granite Tunnel', '🚇'),
  beach('beach', 'Sunset Beach', '🏖️'),
  coast('coast', 'Lighthouse Point', '🗼'),
  town('town', 'Downtown', '🏙️');

  const ScenicPlace(this.wire, this.title, this.icon);
  @override
  final String wire;

  /// What it's called (TS PLACES[place].name).
  final String title;
  final String icon;
}

typedef _Knot = ({double x, double z, ScenicPlace? place});

/// The road's middle, as knots a smooth curve runs through: the whole loop, clockwise seen from above
/// (east along the street, then south, west and back north). `place` marks where each bit starts.
/// The knots either side of each end of the street are in line with it, so the loop leaves it and
/// comes back onto it dead straight; so are the four round the tunnel.
const List<_Knot> _knots = [
  (x: -40, z: streetZ, place: null),
  (x: 0, z: streetZ, place: null),
  (x: 40, z: streetZ, place: null),
  (x: 80, z: streetZ, place: null),
  (x: streetEnd, z: streetZ, place: ScenicPlace.farm),
  (x: 142, z: streetZ, place: null),
  (x: 172, z: 40, place: null),
  (x: 190, z: 66, place: null),
  (x: 200, z: 96, place: ScenicPlace.forest),
  (x: 194, z: 128, place: null),
  (x: 204, z: 160, place: null),
  (x: 196, z: 192, place: null),
  (x: 206, z: 222, place: null),
  (x: 199, z: 252, place: null),
  (x: 191, z: 280, place: null),
  (x: 196, z: 306, place: ScenicPlace.mountains),
  (x: 184, z: 334, place: null),
  (x: 160, z: 352, place: null),
  (x: 130, z: 360, place: null),
  (x: 100, z: 354, place: null),
  (x: 70, z: 366, place: null),
  (x: 44, z: 372, place: null),
  (x: 10, z: 372, place: ScenicPlace.tunnel),
  (x: -50, z: 372, place: ScenicPlace.mountains),
  (x: -84, z: 372, place: null),
  (x: -114, z: 364, place: null),
  (x: -144, z: 368, place: null),
  (x: -172, z: 358, place: null),
  (x: -196, z: 340, place: ScenicPlace.beach),
  (x: -212, z: 314, place: null),
  (x: -220, z: 284, place: null),
  (x: -214, z: 254, place: null),
  (x: -222, z: 224, place: null),
  (x: -216, z: 194, place: null),
  (x: -223, z: 164, place: null),
  (x: -216, z: 134, place: null),
  (x: -208, z: 104, place: ScenicPlace.coast),
  (x: -196, z: 76, place: null),
  (x: -180, z: 52, place: null),
  (x: -162, z: 36, place: null),
  (x: -142, z: streetZ, place: null),
  (x: -streetEnd, z: streetZ, place: ScenicPlace.town),
  (x: -80, z: streetZ, place: null),
];

/// The tunnel: straight along the road (x) from [x0] west to [x1], at [z].
abstract final class Tunnel {
  static const double x0 = 10;
  static const double x1 = -50;
  static const double z = 372;
  static const double width = 10;
  static const double wall = 4.4;
}

class RoadPoint {
  RoadPoint({required this.x, required this.z, required this.d, this.tx = 0, this.tz = 0, required this.place});

  final double x;
  final double z;

  /// Meters along the loop from where it leaves the street's east end.
  final double d;

  /// Which way the loop goes on from here (a unit vector).
  double tx;
  double tz;
  final ScenicPlace place;
}

typedef _P = ({double x, double z});

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// A point [t] (0–1) of the way from p1 to p2 on a centripetal Catmull–Rom curve through p0..p3.
_P _catmull(_P p0, _P p1, _P p2, _P p3, double t) {
  double knot(_P a, _P b) {
    final k = math.sqrt(_hypot(b.x - a.x, b.z - a.z));
    return k == 0 ? 1e-6 : k;
  }

  const t0 = 0.0;
  final t1 = t0 + knot(p0, p1);
  final t2 = t1 + knot(p1, p2);
  final t3 = t2 + knot(p2, p3);
  final u = t1 + (t2 - t1) * t;
  _P lerp(_P a, _P b, double ta, double tb) {
    final k = (u - ta) / (tb - ta);
    return (x: a.x + (b.x - a.x) * k, z: a.z + (b.z - a.z) * k);
  }

  final a1 = lerp(p0, p1, t0, t1);
  final a2 = lerp(p1, p2, t1, t2);
  final a3 = lerp(p2, p3, t2, t3);
  final b1 = lerp(a1, a2, t0, t2);
  final b2 = lerp(a2, a3, t1, t3);
  return lerp(b1, b2, t1, t2);
}

/// How far apart the loop's points are (m).
const double _spacing = 2;

List<RoadPoint> _buildLoop() {
  final n = _knots.length;
  final start = _knots.indexWhere((k) => k.x == streetEnd && k.z == streetZ);
  final end = _knots.indexWhere((k) => k.x == -streetEnd && k.z == streetZ);
  // Finely along each stretch between knots, from the east end round to the west end.
  final fine = <({double x, double z, ScenicPlace place})>[];
  var place = ScenicPlace.farm;
  for (var i = start; i != end; i = (i + 1) % n) {
    place = _knots[i].place ?? place;
    final ps = [
      for (final o in [-1, 0, 1, 2]) _knots[(i + o + n) % n],
    ];
    _P p(int k) => (x: ps[k].x, z: ps[k].z);
    for (var s = 0; s < 40; s++) {
      final c = _catmull(p(0), p(1), p(2), p(3), s / 40);
      fine.add((x: c.x, z: c.z, place: place));
    }
  }
  fine.add((x: _knots[end].x, z: _knots[end].z, place: ScenicPlace.town));
  // Then evenly, by distance along it.
  final out = <RoadPoint>[];
  var d = 0.0;
  var next = 0.0;
  for (var i = 0; i < fine.length - 1; i++) {
    final a = fine[i];
    final b = fine[i + 1];
    final len = _hypot(b.x - a.x, b.z - a.z);
    while (next <= d + len) {
      final k = (next - d) / len;
      out.add(RoadPoint(x: a.x + (b.x - a.x) * k, z: a.z + (b.z - a.z) * k, d: next, place: a.place));
      next += _spacing;
    }
    d += len;
  }
  final last = fine.last;
  out.add(RoadPoint(x: last.x, z: last.z, d: d, place: ScenicPlace.town));
  for (var i = 0; i < out.length; i++) {
    final a = out[math.max(0, i - 1)];
    final b = out[math.min(out.length - 1, i + 1)];
    var len = _hypot(b.x - a.x, b.z - a.z);
    if (len == 0) len = 1;
    out[i].tx = (b.x - a.x) / len;
    out[i].tz = (b.z - a.z) / len;
  }
  return out;
}

/// The loop from the street's east end round to its west end (the street between is the town's), a
/// point every couple of meters.
final List<RoadPoint> loop = _buildLoop();

/// How long the loop is, from one end of the street round to the other (m).
final double loopLength = loop.last.d;

/// The loop and a few meters of the street before each end of it, which it's measured from (see
/// [nearLoop]): its shoulders carry on that far, so a car keeping to the edge doesn't catch a corner of
/// the street's narrower pavement where the two meet.
const double _overlap = 8;
final List<RoadPoint> _path = [
  RoadPoint(x: streetEnd - _overlap, z: streetZ, d: -_overlap, tx: 1, tz: 0, place: ScenicPlace.farm),
  ...loop,
  RoadPoint(x: -streetEnd + _overlap, z: streetZ, d: loopLength + _overlap, tx: 1, tz: 0, place: ScenicPlace.town),
];

/// The loop's stretches (_path[i] to _path[i + 1]) sorted into squares of the map, to look up quickly.
const double _cellSize = 16;
final Map<String, List<int>> _cells = () {
  final cells = <String, List<int>>{};
  for (var i = 0; i < _path.length - 1; i++) {
    final a = _path[i];
    final b = _path[i + 1];
    const pad = loopPaved + 30;
    for (
      var cx = ((math.min(a.x, b.x) - pad) / _cellSize).floor();
      cx <= ((math.max(a.x, b.x) + pad) / _cellSize).floor();
      cx++
    ) {
      for (
        var cz = ((math.min(a.z, b.z) - pad) / _cellSize).floor();
        cz <= ((math.max(a.z, b.z) + pad) / _cellSize).floor();
        cz++
      ) {
        (cells['$cx,$cz'] ??= []).add(i);
      }
    }
  }
  return cells;
}();

/// The nearest point on the loop's middle to somewhere: how far off it that is, which side (+ is
/// left, going round), and the way along it there.
class OnLoop {
  const OnLoop({
    required this.off,
    required this.side,
    required this.d,
    required this.x,
    required this.z,
    required this.tx,
    required this.tz,
    required this.place,
  });

  /// How far from the loop's middle (m).
  final double off;

  /// Which side of it: +1 on the left going round (the outside of the loop), -1 on the right.
  final int side;

  /// How far round the loop (see [RoadPoint.d]).
  final double d;
  final double x;
  final double z;
  final double tx;
  final double tz;
  final ScenicPlace place;
}

/// Where (x, z) is from the loop, if it's within 30 m or so of it (else null).
OnLoop? nearLoop(double x, double z) {
  final list = _cells['${(x / _cellSize).floor()},${(z / _cellSize).floor()}'];
  if (list == null) return null;
  OnLoop? best;
  var bestSq = double.infinity;
  for (final i in list) {
    final a = _path[i];
    final b = _path[i + 1];
    final ex = b.x - a.x;
    final ez = b.z - a.z;
    var len2 = ex * ex + ez * ez;
    if (len2 == 0) len2 = 1;
    final k = (((x - a.x) * ex + (z - a.z) * ez) / len2).clamp(0.0, 1.0);
    final px = a.x + ex * k;
    final pz = a.z + ez * k;
    final sq = (x - px) * (x - px) + (z - pz) * (z - pz);
    if (sq >= bestSq) continue;
    bestSq = sq;
    final len = math.sqrt(len2);
    final tx = ex / len;
    final tz = ez / len;
    // Left of the way round, with +z toward you: the cross product's sign.
    final side = tx * (z - pz) - tz * (x - px) > 0 ? -1 : 1;
    best = OnLoop(
      off: math.sqrt(sq),
      side: side,
      d: a.d + (b.d - a.d) * k,
      x: px,
      z: pz,
      tx: tx,
      tz: tz,
      place: a.place,
    );
  }
  return best;
}

/// Whether (x, z) is on the loop's road (its shoulder included).
bool onLoop(double x, double z) {
  final at = nearLoop(x, z);
  return at != null && at.off <= loopPaved;
}

/// Which bit of the loop (x, z) is by, or the town, if it's by the street; null anywhere else.
ScenicPlace? placeAt(double x, double z) {
  final at = nearLoop(x, z);
  if (at != null && at.off < 25) return at.place;
  if (x.abs() <= streetEnd && (z - streetZ).abs() < 25) return ScenicPlace.town;
  return null;
}

// ---- What's along it ---------------------------------------------------------------------------

/// The mountains to the south: (x, z, radius at the foot, height). The far ones only show over the near.
const List<(double, double, double, double)> mountains = [
  (-270, 420, 75, 110),
  (-180, 455, 80, 140),
  (-90, 465, 75, 125),
  (5, 480, 90, 170),
  (100, 455, 72, 128),
  (200, 440, 75, 115),
  (290, 360, 62, 95),
  (-130, 590, 110, 200),
  (120, 600, 120, 215),
  (-340, 540, 95, 150),
  (340, 500, 100, 160),
  (0, 690, 130, 240),
];

/// Green foothills between the road and the mountains: (x, z, radius, height).
const List<(double, double, double, double)> foothills = [
  (60, 412, 30, 30),
  (-130, 406, 26, 26),
  (176, 398, 28, 34),
  (-232, 382, 22, 22),
  (276, 262, 30, 30),
];

/// The spur of mountain the tunnel goes through: how far it reaches either side of the road (z), and
/// how high its ridge gets.
abstract final class Ridge {
  static const double north = 30;
  static const double south = 40;
  static const double height = 26;
}

/// The lake inside the loop, under the mountains: its middle and its two half-widths.
abstract final class Lake {
  static const double x = 60;
  static const double z = 306;
  static const double rx = 38;
  static const double rz = 17;
}

/// The creek through the pines, which the road crosses on a bridge: (x, z) along its middle, west to east.
const List<(double, double)> creek = [
  (120, 176),
  (150, 186),
  (176, 180),
  (204, 194),
  (232, 188),
  (262, 202),
  (292, 196),
];

/// A field or a pasture: a box on the ground.
typedef FieldBox = ({double minX, double maxX, double minZ, double maxZ});

/// The farm by the road out of town to the east: the barn, the silo, the windmill, and its fields.
abstract final class Farm {
  static const barn = (x: 96.0, z: 58.0, rotY: -0.25);
  static const silo = (x: 110.0, z: 50.0);
  static const windmill = (x: 128.0, z: -6.0);
  static const List<FieldBox> fields = [
    (minX: 58, maxX: 132, minZ: 70, maxZ: 104),
    (minX: 62, maxX: 150, minZ: -40, maxZ: 14),
  ];

  /// The fenced field the cows are in, by the barn.
  static const FieldBox pasture = (minX: 48, maxX: 86, minZ: 38, maxZ: 62);
}

/// The sea's edge, west of the beach: x at [z]. A few gentle bays, well clear of the road (which
/// keeps to the east of x ≈ -228 up the coast).
double shoreX(double z) => -254 + 5 * math.sin(z / 37) + 3 * math.sin(z / 13 + 1);

/// The lighthouse, on its rocky point out into the sea, and the pier off the beach.
const lighthouse = (x: -274.0, z: 18.0);
const pier = (z: 236.0, length: 44.0, width: 4.0);

/// Checkpoints round the loop, for timing a lap: a car has to pass each of them.
final List<double> checkpoints = [
  for (final k in const [0.15, 0.4, 0.65, 0.9]) k * loopLength,
];
