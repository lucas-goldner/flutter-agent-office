// Where your aim meets a wall, for hanging a picture (aimAtWall in world/gallery.ts).

import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/decor.dart';
import 'package:office_shared/layout.dart' show Floor, Loft, Side;

/// Where a ray from inside the room (office space; [dir] normalized) first meets a wall, within
/// [maxDist] meters (the whole room by default).
({WallId wall, double u, double y})? aimAtWall(vm.Vector3 o, vm.Vector3 d, [double maxDist = 60]) {
  // Only from inside: out on the balcony or down on the street, the walls face the other way.
  if (o.x < Floor.minX || o.x > Floor.maxX || o.z < Floor.minZ || o.z > Floor.maxZ || o.y < 0) return null;
  // The loft's floor hides whatever is past it, from above or below.
  if (d.y != 0) {
    final t = (Loft.y - 0.12 - o.y) / d.y;
    final x = o.x + d.x * t, z = o.z + d.z * t;
    if (t > 0 && x > Loft.minX && x < Loft.maxX && z > Loft.minZ && z < Loft.maxZ) maxDist = math.min(maxDist, t);
  }
  final hits = <(WallId, double)>[
    if (d.z < 0) (Side.north, (Floor.minZ - o.z) / d.z),
    if (d.z > 0) (Side.south, (Floor.maxZ - o.z) / d.z),
    if (d.x < 0) (Side.west, (Floor.minX - o.x) / d.x),
    if (d.x > 0) (Side.east, (Floor.maxX - o.x) / d.x),
  ];
  ({WallId wall, double u, double y})? best;
  var bestT = maxDist;
  for (final (wall, t) in hits) {
    if (!(t > 0 && t < bestT)) continue;
    final y = o.y + d.y * t;
    final u = wall == Side.north || wall == Side.south ? o.x + d.x * t : o.z + d.z * t;
    final w = walls[wall]!;
    if (y < 0 || u < w.min || u > w.max || y > wallTop(wall, u)) continue;
    best = (wall: wall, u: u, y: y);
    bestT = t;
  }
  return best;
}
