// Trees all round the loop, by what's near them, and boulders by the road through the mountains
// (world/scenic/trees.ts). They go in last, round everything else.

import 'dart:math' as math;

import 'package:office_shared/scenic.dart';

import '../collider.dart';
import '../office/outside.dart' show neighbourBoxes;
import 'flora.dart';
import 'kit.dart';

void plantTrees(ScenicKit kit) {
  final rand = kit.rand;
  final neighbours = [for (final b in neighbourBoxes()) (minX: b.minX, maxX: b.maxX, minZ: b.minZ, maxZ: b.maxZ)];
  bool town(double x, double z) =>
      (x.abs() < 64 && z > -64 && z < 40) ||
      (x > -24 && x < 14 && z > 30 && z < 72) ||
      neighbours.any((b) => inBox(b, x, z, 5));
  bool ok(double x, double z, double r) =>
      kit.free(x, z, r) &&
      !town(x, z) &&
      x > shoreX(z) + 26 &&
      !mountains.any((m) => math.sqrt(math.pow(m.$1 - x, 2) + math.pow(m.$2 - z, 2)) < m.$3 * 0.95);
  String pick(List<String> from) => from[(rand() * from.length).floor()];

  // The pines: thick right up to the road, thinning out further off, with a leafy tree here and there.
  for (var x = 110.0; x < 320; x += 5.5) {
    for (var z = 50.0; z < 340; z += 5.5) {
      final px = x + (rand() - 0.5) * 4.4;
      final pz = z + (rand() - 0.5) * 4.4;
      final n = nearest(px, pz);
      if (n.place != ScenicPlace.forest ||
          n.off > 100 ||
          rand() > (n.off < 40 ? 0.8 : 0.8 - ((n.off - 40) / 60) * 0.6) ||
          !ok(px, pz, 1.4)) {
        continue;
      }
      final s = 0.85 + rand() * 0.7;
      if (rand() < 0.82) {
        pine(kit.of(Stretch.forest), px, pz, s, pick(pines), rand() * 6);
      } else {
        leafy(kit.of(Stretch.forest), px, pz, s * 0.9, rand() < 0.35 ? pick(autumn) : pick(leaves), rand() * 6);
      }
      if (n.off < 35) kit.trunk(px, pz, 0.26 * s, 2.2 * s);
      kit.take(px, pz, 1.2);
    }
  }
  // Pines scattered up to the mountains and round the lake.
  for (var x = -260.0; x < 300; x += 9) {
    for (var z = 250.0; z < 440; z += 9) {
      final px = x + (rand() - 0.5) * 7;
      final pz = z + (rand() - 0.5) * 7;
      final n = nearest(px, pz);
      if ((n.place != ScenicPlace.mountains && n.place != ScenicPlace.tunnel) ||
          n.off > 80 ||
          rand() > 0.38 ||
          !ok(px, pz, 1.6)) {
        continue;
      }
      final s = 0.9 + rand() * 0.8;
      pine(kit.of(Stretch.mountains), px, pz, s, pick(pines), rand() * 6);
      if (n.off < 30) kit.trunk(px, pz, 0.26 * s, 2.2 * s);
      kit.take(px, pz, 1.5);
    }
  }
  // Palms along the coast road, and on the sand.
  for (final s in [...stretch(ScenicPlace.beach), ...stretch(ScenicPlace.coast)]) {
    for (var d = s.from; d < s.to; d += 7 + rand() * 9) {
      final i = indexAt(d);
      for (final side in const [1, -1]) {
        if (rand() < 0.35) continue;
        final at = beside(i, side * (loopPaved + 3 + rand() * (side > 0 ? 16 : 8)));
        if (!kit.free(at.x, at.z, 1.2) || at.x < shoreX(at.z) + 6) continue;
        final sc = 0.9 + rand() * 0.45;
        palm(kit.of(Stretch.beach), at.x, at.z, sc, rand() * 6);
        kit.trunk(at.x, at.z, 0.2 * sc, 6 * sc);
        kit.take(at.x, at.z, 2);
      }
    }
  }
  // Leafy trees out in the fields and the meadows, inside the loop and out, well off the road.
  for (var x = -250.0; x < 320; x += 15) {
    for (var z = -260.0; z < 330; z += 15) {
      final px = x + (rand() - 0.5) * 12;
      final pz = z + (rand() - 0.5) * 12;
      final n = nearest(px, pz);
      if (n.place == ScenicPlace.forest && n.off < 100) continue;
      if (rand() > (insideLoop(px, pz) ? 0.3 : 0.18) ||
          !ok(px, pz, 3) ||
          Farm.fields.any((f) => inBox(f, px, pz, 3)) ||
          inBox(Farm.pasture, px, pz, 3)) {
        continue;
      }
      if (math.sqrt(math.pow(px - Lake.x, 2) + math.pow((pz - Lake.z) * 2, 2)) < Lake.rx + 8) continue;
      final s = 0.8 + rand() * 0.6;
      final into = n.place == ScenicPlace.beach || n.place == ScenicPlace.coast
          ? Stretch.coast
          : n.place == ScenicPlace.farm
          ? Stretch.farm
          : Stretch.meadow;
      leafy(kit.of(into), px, pz, s, rand() < 0.12 ? pick(autumn) : pick(leaves), rand() * 6);
      kit.trunk(px, pz, 0.28 * s, 2.1 * s);
      kit.take(px, pz, 3);
    }
  }
  // Boulders by the road through the mountains.
  for (final s in stretch(ScenicPlace.mountains)) {
    for (var d = s.from; d < s.to; d += 14 + rand() * 20) {
      final at = beside(indexAt(d), (rand() < 0.6 ? 1 : -1) * (loopPaved + 4 + rand() * 12));
      if (!kit.free(at.x, at.z, 1.5)) continue;
      final r = 0.8 + rand() * 1.6;
      boulder(kit.of(Stretch.mountains), at.x, at.z, r, rand() * 6);
      kit.colliders.add(
        Collider(
          minX: at.x - r * 0.7,
          maxX: at.x + r * 0.7,
          minZ: at.z - r * 0.7,
          maxZ: at.z + r * 0.7,
          bottom: G,
          top: G + r * 0.9,
        ),
      );
      kit.take(at.x, at.z, r + 1);
    }
  }
}
