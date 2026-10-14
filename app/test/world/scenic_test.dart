// The scenic loop's layout (world/scenic/): the same every time, and nothing in the way on the road.

import 'dart:math' as math;

import 'package:agent_office/world/scenic/kit.dart';
import 'package:agent_office/world/scenic/scenic.dart';
import 'package:agent_office/world/office/office_colliders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/garage.dart' show Car, GroundBox, carFits, onPavement;
import 'package:office_shared/layout.dart' show streetY;
import 'package:office_shared/scenic.dart';

void main() {
  final plan = planScenic();
  final kit = plan.kit;

  test('it is laid out the same every time, so everyone drives past the same trees', () {
    final again = planScenic().kit;
    expect(again.colliders.length, kit.colliders.length);
    for (var i = 0; i < kit.colliders.length; i += 37) {
      expect(again.colliders[i].minX, kit.colliders[i].minX);
      expect(again.colliders[i].maxZ, kit.colliders[i].maxZ);
    }
    int pieces(ScenicKit k) => k.parts.values.fold(0, (n, l) => n + l.length);
    expect(pieces(again), pieces(kit));
    // A wood of pines, palms on the coast, and trees out in the meadows.
    expect(kit.of(Stretch.forest).length, greaterThan(500));
    expect(kit.of(Stretch.beach).length, greaterThan(50));
    expect(kit.of(Stretch.meadow).length, greaterThan(20));
  });

  test('nothing stands in the road all the way round, so a car can drive it', () {
    // What a car bumps into stands on the street: the trunks, the farm, the tunnel's rock, the sea.
    final solids = [
      for (final c in [...kit.colliders, ...streetColliders()])
        if ((c.bottom ?? 0) <= streetY + 1 && c.top >= streetY + 0.3)
          GroundBox(minX: c.minX, maxX: c.maxX, minZ: c.minZ, maxZ: c.maxZ),
    ];
    for (var i = 0; i < loop.length; i += 2) {
      final p = loop[i];
      final pose = (x: p.x, z: p.z, rotY: math.atan2(p.tx, p.tz));
      expect(onPavement(pose), isTrue);
      final near = [
        for (final b in solids)
          if (b.minX < p.x + 6 && b.maxX > p.x - 6 && b.minZ < p.z + 6 && b.maxZ > p.z - 6) b,
      ];
      expect(
        carFits(pose, near),
        isTrue,
        reason: 'something in the road at (${p.x.toStringAsFixed(0)}, ${p.z.toStringAsFixed(0)})',
      );
    }
    expect(Car.width, greaterThan(0));
  });

  test('the sea stops you, but the shallows and the pier do not', () {
    bool blocked(double x, double z) => kit.colliders.any(
      (c) => c.fence && c.top > streetY + 1 && x > c.minX && x < c.maxX && z > c.minZ && z < c.maxZ,
    );
    expect(blocked(shoreX(100) - 20, 100), isTrue, reason: 'out to sea');
    expect(blocked(shoreX(100) - 3, 100), isFalse, reason: 'paddling');
    expect(blocked(shoreX(pier.z) - 20, pier.z), isFalse, reason: 'out along the pier');
  });
}
