// The floors above and below this one, worked out without a GPU: which holes go through the floor
// and the ceiling, and what you bump into round the ladder and the fire poles (the colliders
// stack.ts pushes in Stack.set). stack.dart builds what you see from the same numbers.

import 'dart:math' as math;

import 'package:office_shared/layout.dart';

import '../collider.dart';

/// A rectangle on the floor plan.
class PlanRect {
  PlanRect(this.minX, this.maxX, this.minZ, this.maxZ);

  double minX;
  double maxX;
  double minZ;
  double maxZ;

  @override
  String toString() => 'PlanRect($minX..$maxX, $minZ..$maxZ)';
}

/// Which floor of the building you're on (0 is the bottom one), how many there are, and the names
/// of the floors above and below, for the signs.
class StackState {
  const StackState({this.index = 0, this.count = 1, this.up, this.down});

  final int index;
  final int count;
  final String? up;
  final String? down;

  /// Whether there's anywhere to go: another floor.
  bool get others => count > 1;

  /// A floor below this one: the ladder and the poles go on down through holes in the floor.
  bool get below => others && index > 0;

  /// A floor above: the ladder goes up through a hatch in the ceiling, the poles come down through it.
  bool get above => others && index < count - 1;

  @override
  bool operator ==(Object other) =>
      other is StackState && other.index == index && other.count == count && other.up == up && other.down == down;

  @override
  int get hashCode => Object.hash(index, count, up, down);
}

/// The building's footprint, walls included.
final PlanRect _building = PlanRect(Floor.minX - wallT, Floor.maxX + wallT, Floor.minZ - wallT, Floor.maxZ + wallT);

/// The ladder's hatch in the floor and the ceiling.
PlanRect get ladderHatch => PlanRect(Ladder.hatch.minX, Ladder.hatch.maxX, Ladder.hatch.minZ, Ladder.hatch.maxZ);

/// The ladder's rails stand this far out from the west wall.
const double ladderRailX = Floor.minX + 0.16;

/// [r] less the [holes] in it, as a few rectangles: rows of the grid the holes' edges make, stacked
/// where they line up.
List<PlanRect> cutRect(PlanRect r, List<PlanRect> holes) {
  final hs = [
    for (final h in holes)
      PlanRect(math.max(r.minX, h.minX), math.min(r.maxX, h.maxX), math.max(r.minZ, h.minZ), math.min(r.maxZ, h.maxZ)),
  ].where((h) => h.maxX > h.minX && h.maxZ > h.minZ).toList();
  List<double> edges(double lo, double hi, Iterable<double> more) => ({lo, hi, ...more}.toList()..sort());
  final xs = edges(r.minX, r.maxX, hs.expand((h) => [h.minX, h.maxX]));
  final zs = edges(r.minZ, r.maxZ, hs.expand((h) => [h.minZ, h.maxZ]));
  final out = <PlanRect>[];
  for (var j = 0; j < zs.length - 1; j++) {
    final zm = (zs[j] + zs[j + 1]) / 2;
    PlanRect? run;
    for (var i = 0; i < xs.length - 1; i++) {
      final xm = (xs[i] + xs[i + 1]) / 2;
      if (hs.any((h) => xm > h.minX && xm < h.maxX && zm > h.minZ && zm < h.maxZ)) {
        if (run != null) out.add(run);
        run = null;
      } else if (run != null) {
        run.maxX = xs[i + 1];
      } else {
        run = PlanRect(xs[i], xs[i + 1], zs[j], zs[j + 1]);
      }
    }
    if (run != null) out.add(run);
  }
  // Rows with the same span, one on top of the other, become one.
  for (var i = 0; i < out.length; i++) {
    for (var j = i + 1; j < out.length; j++) {
      final a = out[i], b = out[j];
      if (a.minX == b.minX && a.maxX == b.maxX && a.maxZ == b.minZ) {
        a.maxZ = b.maxZ;
        out.removeAt(j--);
      }
    }
  }
  return out;
}

/// The square round a pole's hole.
PlanRect around(double x, double z, double half) => PlanRect(x - half, x + half, z - half, z + half);

Collider _box(PlanRect r, {required double top, double? bottom}) =>
    Collider(minX: r.minX, maxX: r.maxX, minZ: r.minZ, maxZ: r.maxZ, top: top, bottom: bottom);

/// The railing round three sides of a pole's hole, open toward the pole's `open`: as footprints.
List<PlanRect> poleRails(PoleSpot p) {
  final c = math.cos(p.open).round();
  final sn = math.sin(p.open).round();
  const h = Pole.rail, t = 0.06;
  return [
    for (final (x0, x1, z0, z1) in const [
      (-h - t, h + t, -h - t, -h + t),
      (-h - t, -h + t, -h - t, h),
      (h - t, h + t, -h - t, h),
    ])
      () {
        final xs = [x0 * c + z0 * sn, x1 * c + z1 * sn];
        final zs = [-x0 * sn + z0 * c, -x1 * sn + z1 * c];
        return PlanRect(
          p.x + xs.reduce(math.min),
          p.x + xs.reduce(math.max),
          p.z + zs.reduce(math.min),
          p.z + zs.reduce(math.max),
        );
      }(),
  ];
}

/// What you bump into and stand on for the floor, the ceiling, the ladder and the poles, on the
/// floor [s] says you're on (the colliders Stack.set pushes).
List<Collider> stackColliders(StackState s) {
  final out = <Collider>[];
  // Every pole goes the whole way down: through this floor if there's one below.
  final holes = s.below ? poles : const <PoleSpot>[];
  // You can walk over the ladder's hatch (its trapdoor), but not over a pole's hole: that's how you go down it.
  for (final r in cutRect(_building, [for (final p in holes) around(p.x, p.z, Pole.hole - 0.1)])) {
    out.add(_box(r, bottom: -slab, top: 0));
  }
  // Down the hole, the pole is right there to grab; this only catches anyone who somehow isn't sliding.
  for (final p in holes) {
    out.add(_box(around(p.x, p.z, Pole.hole), bottom: -1.4, top: -1.2));
  }
  // The ceiling, and the slab over it.
  out.add(
    Collider(
      minX: Floor.minX,
      maxX: Floor.maxX,
      minZ: Floor.minZ,
      maxZ: Floor.maxZ,
      bottom: wallHeight,
      top: wallHeight + slab,
    ),
  );
  if (s.others) {
    out.add(
      Collider(
        minX: Floor.minX,
        maxX: ladderRailX + 0.05,
        minZ: Ladder.z - Ladder.width / 2 - 0.05,
        maxZ: Ladder.z + Ladder.width / 2 + 0.05,
        top: 99,
      ),
    );
  }
  for (final p in poles) {
    if (s.below) {
      for (final r in poleRails(p)) {
        out.add(_box(r, top: 1.05));
      }
    } else if (s.others) {
      out.add(_box(around(p.x, p.z, Pole.radius + 0.03), top: 99));
    }
  }
  return out;
}

/// Whether someone at (x, z) is in the ladder's hatch (or right by it).
bool inHatch(double x, double z) =>
    x > Ladder.hatch.minX - 0.1 && x < Ladder.hatch.maxX && z > Ladder.hatch.minZ - 0.1 && z < Ladder.hatch.maxZ + 0.1;

/// Which hatches someone wants open, being where they are: the floor's (down the shaft, or low on
/// the ladder) and the ceiling's (up near it).
({bool floor, bool ceiling}) hatchesWanted(double x, double y, double z, {bool onLadder = false}) {
  if (!inHatch(x, z)) return (floor: false, ceiling: false);
  return (
    floor: y < -0.03 || (onLadder && y < 0.6),
    ceiling: y > wallHeight - 1.75 || (onLadder && y > wallHeight - 2.4),
  );
}

/// A pole whose hole (or railing) someone at (x, z) is standing in, when the poles go down from here.
PoleSpot? poleUnder(double x, double z, double slack) {
  for (final s in poles) {
    if (math.max((x - s.x).abs(), (z - s.z).abs()) <= Pole.rail + slack) return s;
  }
  return null;
}
