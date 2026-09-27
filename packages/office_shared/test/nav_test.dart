// Port of tests/nav.test.ts.
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('a worker sent home walks round the furniture, out the exit door and off along the sidewalk', () {
    for (final seat in seats) {
      final way = wayHome(seat);
      // It hops down right beside where it sat.
      expect(math.sqrt(math.pow(way[0].$1 - seat.x, 2) + math.pow(way[0].$2 - seat.z, 2)), lessThan(1.2), reason: '${seat.id} hops down beside its seat');
      final out = way.indexWhere((p) => p.$1 < Floor.minX);
      expect(out, greaterThan(1), reason: '${seat.id} leaves by the exit');
      // From the aisle to the door, every step is on open floor.
      for (var i = 2; i < out; i++) {
        final (x0, z0) = way[i - 1];
        final (x1, z1) = way[i];
        final n = (math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0)) / 0.2).ceil();
        for (var k = 0; k <= n; k++) {
          final x = x0 + ((x1 - x0) * k) / n;
          final z = z0 + ((z1 - z0) * k) / n;
          expect(walkable(x, z), isTrue, reason: '${seat.id} walks into something at (${x.toStringAsFixed(2)}, ${z.toStringAsFixed(2)})');
        }
      }
      // Through the doorway, not the wall beside it.
      for (final (_, z) in [way[out - 1], way[out]]) {
        expect((z - exitDoor.u).abs(), lessThan(exitDoor.width / 2 - 0.2), reason: '${seat.id} goes through the door');
      }
      // Down the steps outside, then away along the sidewalk.
      expect(way.sublist(out).every((p) => p.$1 < ExitStairs.minX + 1 || p.$2 > Road.minZ - 2.1), isTrue, reason: '${seat.id} stays off the building');
      final (ex, ez) = way.last;
      expect(ez > Road.minZ - 2 && ez < Road.minZ && ex < ExitStairs.minX - 10, isTrue, reason: '${seat.id} ends up down the sidewalk');
    }
  });

  void expectPts(List<Pt> actual, List<List<double>> expected) {
    expect(actual.length, expected.length, reason: '$actual');
    for (var i = 0; i < expected.length; i++) {
      expect(actual[i].$1, closeTo(expected[i][0], 1e-9));
      expect(actual[i].$2, closeTo(expected[i][1], 1e-9));
    }
  }

  test('route matches the TS corners across the room', () {
    // Expected values from running src/shared/nav.ts.
    expectPts(route((-15, -10), (15, 10)), [
      [-15, -10],
      [-6.75, -4.75],
      [9.25, 9.25],
      [15, 10],
    ]);
  });

  test('route stays on open floor and keeps its ends', () {
    final r = route((-15, -10), (15, 10));
    expect(r.first, (-15.0, -10.0));
    expect(r.last, (15.0, 10.0));
    for (final (x, z) in r.skip(1).take(r.length - 2)) {
      expect(walkable(x, z), isTrue);
    }
  });

  test('wayHome matches the TS for a desk and a bean bag', () {
    expectPts(wayHome(desks[0]), [
      [-12.299999999999999, -5.5],
      [-12.299999999999999, -6.3],
      [-13.25, -5.25],
      [-14.75, 4.25],
      [-17.25, 6.25],
      [-19.1, 6.5],
      [-19.1, 12.860000000000001],
      [-19.1, 21.3],
      [-38, 21.3],
    ]);
    expectPts(wayHome(beanbags[3]), [
      [-16, -1.95],
      [-14.850000000000001, -1.95],
      [-14.75, 4.25],
      [-17.25, 6.25],
      [-19.1, 6.5],
      [-19.1, 12.860000000000001],
      [-19.1, 21.3],
      [-38, 21.3],
    ]);
  });

  test('nearestWalkable leaves open floor alone and moves off furniture', () {
    expect(nearestWalkable((0.0, 0.0)), (0.0, 0.0));
    final d = desks[0];
    final p = nearestWalkable((d.x, d.z));
    expect(walkable(p.$1, p.$2), isTrue);
  });
}
