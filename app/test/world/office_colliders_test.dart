// The office's colliders, worked out without a GPU: the numbers office.ts pushes, which the player
// and nav depend on.
import 'dart:math' as math;

import 'package:agent_office/shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;
import 'package:agent_office/world/collider.dart';
import 'package:agent_office/world/office/geo.dart' show triangulate;
import 'package:agent_office/world/office/office_colliders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

Matcher box(double minX, double maxX, double minZ, double maxZ, double top, [double? bottom]) => isA<Collider>()
    .having((c) => c.minX, 'minX', closeTo(minX, 1e-9))
    .having((c) => c.maxX, 'maxX', closeTo(maxX, 1e-9))
    .having((c) => c.minZ, 'minZ', closeTo(minZ, 1e-9))
    .having((c) => c.maxZ, 'maxZ', closeTo(maxZ, 1e-9))
    .having((c) => c.top, 'top', closeTo(top, 1e-9))
    .having((c) => c.bottom, 'bottom', bottom == null ? isNull : closeTo(bottom, 1e-9));

void main() {
  final all = officeColliders();

  test('a desk blocks its top, a little inside its edges', () {
    // desk-1: the back row of the north-west pod, x -10.5 - 1.1, z -4.55.
    expect(desks.first.id, 'desk-1');
    expect(deskCollider(desks.first), box(-12.65, -10.55, -5.08, -4.02, 0.78));
    for (final d in desks) {
      expect(all.where((c) => c.minX == d.x - 1.05 && c.minZ == d.z - 0.53 && c.top == DeskSize.height), hasLength(1));
    }
  });

  test('the loft floor tops out at 3, over a slab you walk under', () {
    final loft = loftColliders();
    expect(loft.first, box(Loft.minX, Loft.maxX, Loft.minZ, Loft.maxZ, 3, 2.75));
    expect(all, contains(box(9, 18, 8, 13, 3, 2.75)));
    // Its roof, and the wall over the door at the top of the stairs.
    expect(loft, contains(box(9, 18, 8, 13, 6.0, 5.8)));
    expect(loft, contains(box(9, 9.12, 11.2, 13, 5.8, 5.3)));
  });

  test('the loft stairs climb one step at a time to the loft floor', () {
    final steps = loftColliders().where((c) => c.minZ == Stairs.minZ && c.maxZ == Stairs.maxZ && c.bottom == null && c.top < 99).toList();
    expect(steps, hasLength(Stairs.steps));
    for (var i = 0; i < steps.length; i++) {
      expect(steps[i].top, closeTo((i + 1) * 0.2, 1e-9));
      expect(steps[i].minX, closeTo(Stairs.fromX + i * 0.4, 1e-9));
      if (i > 0) expect(steps[i].top, greaterThan(steps[i - 1].top));
    }
    expect(steps.last.top, closeTo(Loft.y, 1e-9));
  });

  test('the exit stairs step down from the landing to the street', () {
    final ex = exitStairsColliders();
    expect(ex.first, box(-19.9, -18.3, 5.6, 7.5, 0, streetY));
    final treads = ex.skip(1).take(ExitStairs.steps - 1).toList();
    for (var i = 0; i < treads.length; i++) {
      expect(treads[i].top, closeTo(-(i + 1) * 0.24, 1e-9));
      expect(treads[i].minZ, closeTo(7.5 + i * 0.34, 1e-9));
    }
  });

  test('the walls let you through the doors, under the wall above them', () {
    final walls = wallsPlan().colliders;
    // The exit door, in the west wall.
    expect(walls, contains(box(-18.3, -18, 5.8, 7.2, 99, 2.4)));
    // The balcony doors, in the south wall.
    expect(walls, contains(box(-5.5, -2.5, 13, 13.3, 99, 2.5)));
    // Beside them, solid wall down to the floor.
    expect(walls, contains(box(-18.3, -18, -13, 5.8, 99)));
    expect(walls.where((c) => c.bottom != null), hasLength(2));
  });

  test('bean bags and cars are turned the way they face', () {
    final bag = beanbags.firstWhere((b) => b.id == 'beanbag-3');
    expect(beanbagCollider(bag), box(-17.2, -15.46, -9.62, -8.38, 0.62));
    final front = parkedCars.last;
    expect(carColliders(front).first, box(6.78, 11.22, 17.28, 19.12, streetY + 0.82, streetY));
  });

  test('the elevator doors are the last of its colliders, and open for walking', () {
    final el = elevatorColliders();
    expect(el, hasLength(5));
    expect(el.last, box(7.8, 9.2, -10.8, -10.6, 99));
    el.last.top = -1;
    expect(officeColliders(elevator: el), contains(same(el.last)));
  });

  test('ear clipping fills a square with a round hole, and nothing more', () {
    final outer = [vm.Vector2(0, 0), vm.Vector2(2, 0), vm.Vector2(2, 2), vm.Vector2(0, 2)];
    final hole = [for (var i = 0; i < 16; i++) vm.Vector2(1 + 0.5 * math.cos(-i / 16 * math.pi * 2), 1 + 0.5 * math.sin(-i / 16 * math.pi * 2))];
    final tris = triangulate(outer, [hole]);
    final pts = [...outer, ...hole];
    var area = 0.0;
    for (var i = 0; i < tris.length; i += 3) {
      final a = pts[tris[i]], b = pts[tris[i + 1]], c = pts[tris[i + 2]];
      final cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
      expect(cross, greaterThan(0), reason: 'every triangle winds counter-clockwise');
      area += cross / 2;
    }
    var holeArea = 0.0;
    for (var i = 0; i < hole.length; i++) {
      final p = hole[i], q = hole[(i + 1) % hole.length];
      holeArea += (p.x * q.y - q.x * p.y) / 2;
    }
    expect(area, closeTo(4 + holeArea, 1e-9)); // holeArea is negative: the hole runs clockwise
  });
}
