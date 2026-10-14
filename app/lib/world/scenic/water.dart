// The creek under the bridge, the lake under the mountains and the sea past the beach
// (world/scenic/water.ts).

import 'dart:math' as math;

import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import 'flora.dart';
import 'kit.dart';
import 'road.dart';

/// The water. Returns the surf's look, whose opacity comes and goes (see Scenic.update).
///
/// TODO(port): the TS also slides the water's ripples along (its textures' offsets); the toon
/// material has no texture transform, so here the water lies still.
Coat buildWater(ScenicKit kit, RoadInfo road) {
  final rand = kit.rand;
  final creekLine = road.creekLine;
  final bridge = road.bridge;
  // The creek: a ribbon of water between muddy banks, under the bridge.
  {
    final line = withTangents(creekLine);
    var run = 0.0;
    final along = [
      for (var i = 0; i < line.length; i++)
        i == 0
            ? 0.0
            : (run += math.sqrt(math.pow(line[i].x - line[i - 1].x, 2) + math.pow(line[i].z - line[i - 1].z, 2))),
    ];
    final xs = creekLine.map((q) => q.x), zs = creekLine.map((q) => q.z);
    final seen = Seen(
      xs.reduce(math.min) - 5,
      xs.reduce(math.max) + 5,
      zs.reduce(math.min) - 5,
      zs.reduce(math.max) + 5,
    );
    // The banks either side of the water (not under it, which would fight it for the same pixels).
    const mud = Coat.flat('#a68a64');
    kit.root
      ..add(Loose(strip(line, 2.7, 4.5, G - 0.022, (_) => 0), mud, seen: seen))
      ..add(Loose(strip(line, -4.5, -2.7, G - 0.022, (_) => 0), mud, seen: seen))
      ..add(
        Loose(
          strip(line, -2.8, 2.8, G - 0.018, (i) => along[i] / 10),
          const Coat.flat('#ffffff', canvas: Painted.creek),
          seen: seen,
        ),
      );
    for (final p in creekLine) {
      kit.take(p.x, p.z, 5);
    }
    // The bridge's wooden railings, either side of the road over it.
    const wood = Coat.plain('#8b5e34');
    for (final side in const [-1, 1]) {
      final i0 = indexAt(bridge - 9), i1 = indexAt(bridge + 9);
      for (var i = i0; i <= i1; i++) {
        final a = beside(i, side * (loopPaved + 0.35));
        kit.put(Stretch.forest, box(0.25, 1.1, 0.25), wood, x: a.x, y: G + 0.55, z: a.z);
        if (i < i1) {
          final b = beside(i + 1, side * (loopPaved + 0.35));
          final len = math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.z - a.z, 2));
          kit.put(
            Stretch.forest,
            box(0.14, 0.18, len + 0.1),
            wood,
            x: (a.x + b.x) / 2,
            y: G + 1.0,
            z: (a.z + b.z) / 2,
            rot: yawQ(math.atan2(b.x - a.x, b.z - a.z)),
          );
        }
      }
    }
  }
  // The lake under the mountains, a shore of sand round it and a little dock.
  {
    final seen = Seen(Lake.x - Lake.rx - 4, Lake.x + Lake.rx + 4, Lake.z - Lake.rz - 4, Lake.z + Lake.rz + 4);
    kit.root
      ..add(
        Loose(
          flatEllipse(Lake.rx + 3.5, Lake.rz + 3.5, irx: Lake.rx - 0.1, irz: Lake.rz - 0.1),
          const Coat.flat('#e9d8a6'),
          at: vm.Matrix4.translationValues(Lake.x, G - 0.022, Lake.z),
          seen: seen,
        ),
      )
      ..add(
        Loose(
          flatEllipse(Lake.rx, Lake.rz, su: 6, sv: 3),
          const Coat.flat('#ffffff', canvas: Painted.lake),
          at: vm.Matrix4.translationValues(Lake.x, G - 0.018, Lake.z),
          seen: seen,
        ),
      );
    kit.take(Lake.x, Lake.z, Lake.rx + 6);
    const wood = Coat.plain('#9c6644');
    final dock = (x: Lake.x - 6, z: Lake.z - Lake.rz - 1);
    kit.put(Stretch.mountains, box(2.4, 0.2, 9), wood, x: dock.x, y: G + 0.25, z: dock.z + 3.5);
    for (final (dx, dz) in const [(-1.1, 0.0), (1.1, 0.0), (-1.1, 7.8), (1.1, 7.8)]) {
      kit.put(Stretch.mountains, cyl(0.12, 0.12, 1.2, 6), wood, x: dock.x + dx, y: G + 0.2, z: dock.z + dz);
    }
    kit.put(
      Stretch.mountains,
      box(1.1, 0.5, 2.6),
      const Coat.plain('#e63946'),
      x: dock.x + 2.6,
      y: G - 0.02,
      z: dock.z + 6.5,
    );
    for (var k = 0; k < 9; k++) {
      final a = rand() * math.pi * 2;
      boulder(
        kit.of(Stretch.mountains),
        Lake.x + math.cos(a) * (Lake.rx + 2),
        Lake.z + math.sin(a) * (Lake.rz + 2),
        0.8 + rand() * 1.4,
        rand() * 6,
      );
    }
  }
  // The sea, west past the beach as far as you can see, the sand sloping down into it, and surf.
  const surf = Coat.flat('#ffffff', opacity: 0.7);
  {
    kit.root.add(
      Loose(
        flatPlane(1300, 1800, 90, 125),
        const Coat.flat('#ffffff', canvas: Painted.sea),
        at: vm.Matrix4.translationValues(-240 - 650, G - 0.15, 0),
      ),
    );
    final coast = <XZ>[];
    for (var z = -900.0; z <= 900; z += z > -300 && z < 600 ? 4 : 30) {
      coast.add((x: shoreX(z), z: z));
    }
    final line = withTangents(coast);
    // Going south (+z) along it, the land's on the left (+): flat sand up from the water's edge, and
    // under the water it slopes away, so the sea's surface meets it right at the edge.
    const sand = Coat.flat('#f2dfae');
    kit.root
      ..add(Loose(strip(line, 4, 28, G - 0.015, (_) => 0), sand))
      ..add(Loose(strip(line, -10, 4, 0, (_) => 0, ys: (_, side) => side == 'l' ? G - 0.015 : G - 0.5), sand))
      ..add(Loose(strip(line, -2.6, 0.2, G - 0.135, (_) => 0), surf));
    // Walk into the shallows, or out along the pier, but not out to sea.
    final bands = [(-400.0, pier.z - pier.width / 2), (pier.z + pier.width / 2, 640.0)];
    for (final (z0, z1) in bands) {
      for (var z = z0; z < z1; z += 40) {
        final zEnd = math.min(z1, z + 40);
        var x = double.infinity;
        for (var k = z; k <= zEnd; k += 2) {
          x = math.min(x, shoreX(k));
        }
        kit.colliders.add(
          Collider(minX: -1600, maxX: x - 6, minZ: z, maxZ: zEnd, bottom: G - 1, top: G + 2, fence: true),
        );
      }
    }
    kit.colliders.add(
      Collider(
        minX: -1600,
        maxX: shoreX(pier.z) - pier.length - 0.2,
        minZ: pier.z - pier.width / 2,
        maxZ: pier.z + pier.width / 2,
        bottom: G - 1,
        top: G + 2,
        fence: true,
      ),
    );
  }
  return surf;
}
