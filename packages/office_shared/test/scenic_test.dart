// The shared part of tests/scenic.test.ts (lap timing is the client's, the Garage the server's).
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

double hypot(double a, double b) => math.sqrt(a * a + b * b);

void main() {
  test('the loop leaves one end of the street and comes back to the other, dead straight and in one piece', () {
    final first = loop.first;
    final last = loop.last;
    expect([first.x, first.z], [streetEnd, streetZ]);
    expect([last.x, last.z], [-streetEnd, streetZ]);
    expect(first.tx > 0.999 && last.tx > 0.999, isTrue, reason: 'in line with the street at both ends');
    for (var i = 1; i < loop.length; i++) {
      expect(hypot(loop[i].x - loop[i - 1].x, loop[i].z - loop[i - 1].z), lessThan(2.01), reason: 'no gap at $i');
    }
    expect(loopLength, greaterThan(1000));
  });

  test('no bend on it is tighter than a car can take flat out, and a car fits on it all the way round', () {
    final tightest = Drive.wheelbase / math.tan(steerLimit(Drive.top));
    for (var i = 3; i < loop.length - 3; i++) {
      final a = loop[i - 3];
      final b = loop[i + 3];
      final d = math.atan2(b.tx, b.tz) - math.atan2(a.tx, a.tz);
      final turn = math.atan2(math.sin(d), math.cos(d)).abs();
      final radius = (b.d - a.d) / (turn == 0 ? 1e-9 : turn);
      expect(radius, greaterThan(tightest), reason: 'a bend at (${loop[i].x}, ${loop[i].z})');
    }
    for (final p in loop) {
      final rotY = math.atan2(p.tx, p.tz);
      expect(onPavement((x: p.x, z: p.z, rotY: rotY)), isTrue, reason: 'on it at (${p.x}, ${p.z})');
      for (final side in [-1, 1]) {
        final off = side * (loopPaved - Car.width / 2 - 0.35);
        expect(
          onPavement((x: p.x + p.tz * off, z: p.z - p.tx * off, rotY: rotY)),
          isTrue,
          reason: 'over to the side at (${p.x}, ${p.z})',
        );
      }
    }
  });

  test('off the side of the loop is grass: nothing is paved past its shoulder', () {
    for (var i = 0; i < loop.length; i += 5) {
      final p = loop[i];
      if ((p.z - streetZ).abs() < 8 && p.x.abs() < streetEnd + 12) continue;
      for (final side in [-1, 1]) {
        final off = side * (loopPaved + 0.3);
        expect(paved(p.x + p.tz * off, p.z - p.tx * off), isFalse, reason: 'the verge at (${p.x}, ${p.z})');
      }
    }
    expect(paved(0, 200), isFalse, reason: 'nor inside the loop');
  });

  test('nearLoop finds the nearest bit of the loop, as looking at every point would', () {
    var seed = 7;
    double rand() => (seed = (seed * 16807) % 2147483647) / 2147483647;
    for (var k = 0; k < 400; k++) {
      final p = loop[(rand() * loop.length).floor()];
      final x = p.x + (rand() - 0.5) * 40;
      final z = p.z + (rand() - 0.5) * 40;
      var best = double.infinity;
      for (var i = 0; i < loop.length - 1; i++) {
        final a = loop[i];
        final b = loop[i + 1];
        final ex = b.x - a.x;
        final ez = b.z - a.z;
        final t = (((x - a.x) * ex + (z - a.z) * ez) / (ex * ex + ez * ez)).clamp(0.0, 1.0);
        best = math.min(best, hypot(x - a.x - ex * t, z - a.z - ez * t));
      }
      final at = nearLoop(x, z);
      if (best > 30 || (x.abs() < streetEnd + 30 && (z - streetZ).abs() < 30)) continue;
      expect(at != null && (at.off - best).abs() < 1e-6, isTrue, reason: '($x, $z): ${at?.off} vs $best');
    }
    expect(nearLoop(streetEnd + 10, streetZ - 2)!.side, 1);
    expect(nearLoop(streetEnd + 10, streetZ + 2)!.side, -1);
  });

  test('the loop keeps clear of the building, the golf hole, the mountains, the lake, the farm and the sea', () {
    double dist(double x, double z) => loop.map((p) => hypot(p.x - x, p.z - z)).reduce(math.min);
    for (final (x, z, r, _) in [...mountains, ...foothills]) {
      expect(dist(x, z), greaterThan(r + 8), reason: 'the mountain at ($x, $z)');
    }
    for (final p in loop) {
      expect(
        hypot((p.x - Lake.x) / (Lake.rx + 12), (p.z - Lake.z) / (Lake.rz + 12)),
        greaterThan(1),
        reason: 'the lake',
      );
      expect(p.x - shoreX(p.z), greaterThan(20), reason: 'the sea at z ${p.z}');
      expect(
        p.x > Floor.minX - wallT - 10 && p.x < Floor.maxX + wallT + 10 && p.z < Road.maxZ + 30,
        isFalse,
        reason: 'the building',
      );
      expect(hypot(p.x - GolfHole.x, p.z - GolfHole.z), greaterThan(40), reason: 'the golf hole');
      for (final f in [...Farm.fields, Farm.pasture]) {
        expect(
          p.x > f.minX - loopPaved && p.x < f.maxX + loopPaved && p.z > f.minZ - loopPaved && p.z < f.maxZ + loopPaved,
          isFalse,
          reason: 'the fields',
        );
      }
    }
    for (final b in [(x: Farm.barn.x, z: Farm.barn.z), Farm.silo, Farm.windmill]) {
      expect(dist(b.x, b.z), greaterThan(20), reason: 'the farm buildings');
    }
    expect(lighthouse.x, lessThan(shoreX(lighthouse.z)), reason: 'the lighthouse is out in the sea');
    final inside = loop.where((p) => p.x < Tunnel.x0 && p.x > Tunnel.x1 && (p.z - Tunnel.z).abs() < 20).toList();
    expect(inside.length, greaterThan(20));
    for (final p in inside) {
      expect((p.z - Tunnel.z).abs() < 0.01 && p.tx < -0.9999, isTrue, reason: 'straight through at x ${p.x}');
    }
    expect(Tunnel.width / 2, greaterThan(loopPaved));
    expect(loopHalf, (Road.maxZ - Road.minZ) / 2);
  });

  test(
    'each bit of the loop is somewhere: the farm, the pines, the mountains and the tunnel, the beach, the coast, and the town',
    () {
      final along = <ScenicPlace>[];
      for (final p in loop) {
        if (along.isEmpty || along.last != p.place) along.add(p.place);
      }
      expect(
        [for (final p in along) p.wire],
        ['farm', 'forest', 'mountains', 'tunnel', 'mountains', 'beach', 'coast', 'town'],
      );
      expect(placeAt(0, streetZ), ScenicPlace.town);
      expect(placeAt(200, 150), ScenicPlace.forest);
      expect(placeAt(-20, Tunnel.z), ScenicPlace.tunnel);
      expect(placeAt(-218, 250), ScenicPlace.beach);
      expect(placeAt(0, -300), isNull);
      expect(checkpoints.length, 4);
    },
  );
}
