// The beach, the pier and the boats, and the lighthouse out on its point (world/scenic/coast.ts).

import 'dart:math' as math;

import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../office/geo.dart' show Shape2;
import '../office/outside.dart' show Halo;
import '../text.dart' show TextOpts;
import 'flora.dart';
import 'kit.dart';

/// A sailboat out on the water, and where it bobs.
class Boat {
  Boat(this.clump, this.x, this.z, this.turn, this.phase);
  final Clump clump;
  final double x, z;

  /// Which way it points (it rocks about its own length as it bobs).
  final double turn;
  final double phase;
}

/// The lighthouse's beam: where it goes round from, and its two cones of light.
class Beam {
  Beam(this.x, this.y, this.z, this.cones);
  final double x, y, z;
  final List<Clump> cones;
}

/// Two long cones of light (three's ConeGeometry(4.5, 70, 16, 1, true), moved down its length so
/// its tip is at the lamp), brightest at the lamp and fading out along their length, seen from inside
/// and out.
List<double> _beamCone(List<double> col) {
  const r = 4.5, h = 70.0, seg = 16;
  const stops = [(0.0, 1.0), (0.35, 0.45), (1.0, 0.0)];
  final pos = <double>[];
  for (var s = 0; s < stops.length - 1; s++) {
    final (f0, a0) = stops[s];
    final (f1, a1) = stops[s + 1];
    for (var i = 0; i < seg; i++) {
      final t0 = i / seg * math.pi * 2, t1 = (i + 1) / seg * math.pi * 2;
      vm.Vector3 at(double f, double t) => vm.Vector3(math.cos(t) * r * f, -h * f, math.sin(t) * r * f);
      final quad = [(at(f0, t0), a0), (at(f0, t1), a0), (at(f1, t1), a1), (at(f1, t0), a1)];
      for (final idx in const [
        [0, 1, 2],
        [0, 2, 3],
        [0, 2, 1],
        [0, 3, 2],
      ]) {
        for (final k in idx) {
          final (p, a) = quad[k];
          pos.addAll([p.x, p.y, p.z]);
          col.addAll([1, 1, 1, a]);
        }
      }
    }
  }
  return pos;
}

/// The beach, the pier and the boats, and the lighthouse. Returns the boats, to bob, and the beam, to turn.
({List<Boat> boats, Beam beam}) buildCoast(ScenicKit kit) {
  final rand = kit.rand;
  final boats = <Boat>[];
  final b = kit.of(Stretch.beach);
  const colors = ['#ef476f', '#ffd166', '#06d6a0', '#118ab2', '#f78c6b', '#9b5de5'];
  final beach = stretch(ScenicPlace.beach);
  // Umbrellas and towels on the sand.
  for (final s in beach) {
    for (var d = s.from + 10; d < s.to - 6; d += 9 + rand() * 7) {
      final p = loop[indexAt(d)];
      final x = shoreX(p.z) + 9 + rand() * 12;
      final z = p.z + (rand() - 0.5) * 6;
      if ((z - pier.z).abs() < 6) continue;
      final color = colors[(rand() * colors.length).floor()];
      putIn(b, cyl(0.05, 0.05, 2.5, 6), const Coat.plain('#f1f1ee'), x: x, y: G + 1.25, z: z);
      putIn(b, cone(1.5, 0.6, 8), Coat.plain(color), x: x, y: G + 2.45, z: z, rot: eulerQ(0, 0, (rand() - 0.5) * 0.3));
      final towel = Coat.plain(colors[(rand() * colors.length).floor()]);
      putIn(b, box(0.9, 0.03, 1.9), towel, x: x + 1.1, y: G + 0.02, z: z + 0.4, rot: yawQ(rand() * 0.6), shadow: false);
      kit.take(x, z, 2.5);
    }
  }
  // A lifeguard's tower.
  {
    final p = loop[indexAt(beach.first.from + 95)];
    final x = shoreX(p.z) + 12;
    final z = p.z;
    const wood = Coat.plain('#f1f1ee');
    for (final (dx, dz) in const [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]) {
      putIn(b, box(0.2, 2.6, 0.2), wood, x: x + dx, y: G + 1.3, z: z + dz);
    }
    putIn(b, box(2.6, 0.2, 2.6), wood, x: x, y: G + 2.7, z: z);
    putIn(b, box(2.2, 1.6, 2.2), const Coat.plain('#e63946'), x: x, y: G + 3.6, z: z);
    putIn(b, box(2.3, 0.1, 1.5), const Coat.plain('#bde0fe'), x: x - 1.15, y: G + 3.8, z: z);
    putIn(
      b,
      moved(cone(2, 0.9, 4), vm.Matrix4.rotationY(math.pi / 4)),
      const Coat.plain('#fefae0'),
      x: x,
      y: G + 4.85,
      z: z,
    );
    putIn(b, box(0.1, 0.9, 0.6), const Coat.plain('#fefae0'), x: x - 1.12, y: G + 3.9, z: z - 0.2);
    putIn(b, box(0.06, 3, 0.06), const Coat.plain('#3d405b'), x: x + 1, y: G + 5.6, z: z + 1);
    putIn(b, box(0.05, 0.6, 0.9), const Coat.plain('#ffd166'), x: x + 1, y: G + 6.7, z: z + 1.45);
    kit.colliders.add(Collider(minX: x - 1.3, maxX: x + 1.3, minZ: z - 1.3, maxZ: z + 1.3, bottom: G, top: G + 5));
    kit.take(x, z, 3);
  }
  // A beach volleyball net, and the snack shack by the road.
  {
    final p = loop[indexAt(beach.first.from + 175)];
    final x = shoreX(p.z) + 14;
    final z = p.z;
    for (final dz in const [-4.5, 4.5]) {
      putIn(b, cyl(0.07, 0.07, 2.6, 6), const Coat.plain('#f1f1ee'), x: x, y: G + 1.3, z: z + dz);
    }
    putIn(b, box(0.04, 0.9, 9), const Coat.plain('#22223b'), x: x, y: G + 2.1, z: z);
    putIn(b, sphere(0.22, 10, 8), const Coat.plain('#ffd166'), x: x + 3, y: G + 0.22, z: z - 1);
    kit.take(x, z, 6);
  }
  {
    final i = indexAt(beach.first.from + 130);
    final p = loop[i];
    final at = beside(i, loopHalf + 7);
    // Its counter toward the road.
    final turn = math.atan2(p.tz, -p.tx);
    final shack = Clump(x: at.x, y: G, z: at.z)..turn(turn);
    shack.add(box(4.4, 2.6, 3.2), const Coat.plain('#ffcad4'), y: 1.3);
    shack.add(box(5, 0.2, 3.8), const Coat.plain('#fefae0'), y: 2.7);
    for (var k = 0; k < 5; k++) {
      shack.add(
        box(1, 0.08, 1.4),
        Coat.plain(k.isOdd ? '#fefae0' : '#ef476f'),
        x: -2.0 + k,
        y: 2.2,
        z: -2.2,
        rot: eulerQ(-0.35),
      );
    }
    shack.add(box(4.4, 0.9, 0.2), const Coat.plain('#fefae0'), y: 1.1, z: -1.7);
    b.add(shack);
    final sign = yawQ(turn).rotated(vm.Vector3(0, 3.35, -1.95))..add(shack.position);
    kit.labels.add(
      SignText(
        '🍦 Snacks',
        const TextOpts(color: '#3d2b1f', bg: '#fefae0', size: 56),
        x: sign.x,
        y: sign.y,
        z: sign.z,
        rotY: turn + math.pi,
        scale: 1.1,
      ),
    );
    kit.colliders.add(
      Collider(minX: at.x - 2.6, maxX: at.x + 2.6, minZ: at.z - 2.6, maxZ: at.z + 2.6, bottom: G, top: G + 2.8),
    );
    kit.take(at.x, at.z, 5);
  }
  // The pier, out into the sea on posts, with a rail along each side.
  {
    final x0 = shoreX(pier.z) + 8;
    final x1 = shoreX(pier.z) - pier.length;
    const wood = Coat.plain('#b08968');
    const deck = 0.28;
    putIn(b, box(x0 - x1, 0.2, pier.width), wood, x: (x0 + x1) / 2, y: G + deck - 0.1, z: pier.z);
    for (var x = x1 + 1; x < x0; x += 4) {
      for (final s in const [-1, 1]) {
        putIn(
          b,
          cyl(0.16, 0.16, 1.6, 6),
          const Coat.plain('#7f5539'),
          x: x,
          y: G - 0.5,
          z: pier.z + s * (pier.width / 2 - 0.2),
        );
        putIn(b, box(0.12, 1, 0.12), wood, x: x, y: G + deck + 0.5, z: pier.z + s * (pier.width / 2 - 0.1));
      }
    }
    for (final s in const [-1, 1]) {
      putIn(
        b,
        box(x0 - x1 - 4, 0.12, 0.12),
        wood,
        x: (x0 + x1) / 2 - 2,
        y: G + deck + 0.95,
        z: pier.z + s * (pier.width / 2 - 0.1),
      );
    }
    kit.colliders.add(
      Collider(
        minX: x1,
        maxX: x0,
        minZ: pier.z - pier.width / 2,
        maxZ: pier.z + pier.width / 2,
        bottom: G - 1,
        top: G + deck,
      ),
    );
    for (final s in const [-1, 1]) {
      kit.colliders.add(
        Collider(
          minX: x1,
          maxX: x0 - 4,
          minZ: pier.z + s * (pier.width / 2) - 0.1,
          maxZ: pier.z + s * (pier.width / 2) + 0.1,
          bottom: G + deck,
          top: G + deck + 1,
          fence: true,
        ),
      );
    }
    kit.colliders.add(
      Collider(
        minX: x1 - 0.2,
        maxX: x1,
        minZ: pier.z - pier.width / 2,
        maxZ: pier.z + pier.width / 2,
        bottom: G + deck,
        top: G + deck + 1,
        fence: true,
      ),
    );
    kit.take(x0 - 4, pier.z, 6);
    kit.halos.add(Halo(at: vm.Vector3(x1 + 1, G + 2.4, pier.z), size: 1.6, color: '#ffe8a3', ground: true));
    putIn(b, box(0.12, 2.2, 0.12), const Coat.plain('#3d405b'), x: x1 + 1, y: G + 1.3, z: pier.z + 1.7);
    putIn(
      b,
      sphere(0.18, 10, 8),
      const Coat.bulb('#ffe8a3', 0.1),
      x: x1 + 1,
      y: G + 2.4,
      z: pier.z + 1.7,
      shadow: false,
    );
  }
  // Sailboats out on the water, bobbing.
  final hull = Shape2()
    ..moveTo(-2.6, 0.9)
    ..lineTo(2.9, 0.9)
    ..lineTo(2.2, 0)
    ..lineTo(-2.2, 0);
  final sail = Shape2()
    ..moveTo(0, 0)
    ..lineTo(0, 5.6)
    ..lineTo(-2.8, 0);
  final hullMesh = moved(shapeMesh(hull, depth: 1.8), vm.Matrix4.translationValues(0, 0, -0.9));
  // Seen from either side (the TS's is one-sided, so from the other it vanishes).
  final sailMesh = shapeMesh(sail, both: true);
  for (final (x, z) in const [(-300.0, 170.0), (-335.0, 262.0), (-290.0, 330.0), (-320.0, 80.0)]) {
    final g = Clump();
    g.add(hullMesh, const Coat.plain('#fefae0'));
    g.add(cyl(0.07, 0.07, 6.5, 6), const Coat.plain('#6f4e37'), x: 0.3, y: 4);
    final c = Coat.plain(colors[boats.length % colors.length]);
    g.add(sailMesh, c, x: 0.2, y: 1.2);
    final turn = rand() * math.pi * 2;
    boats.add(Boat(g, x, z, turn, rand() * 6));
  }
  // The lighthouse out on its point, rocks to walk out along, and its beam going round at night.
  final c = kit.light;
  final lx = lighthouse.x, lz = lighthouse.z;
  final land = shoreX(lz);
  for (var x = land + 2; x > lx; x -= 3.2) {
    boulder(c, x, lz + (rand() - 0.5) * 3, 1.8 + rand() * 1.4, rand() * 6, '#8d8a99');
  }
  boulder(c, lx, lz, 7.5, 0.4, '#8d8a99');
  boulder(c, lx - 3, lz + 4, 4.5, 1.7, '#77738a');
  const white = Coat.plain('#f8f9fa');
  const red = Coat.plain('#d62828');
  final base = G + 2.4;
  putIn(c, cyl(3.4, 3.8, 2, 12), const Coat.plain('#cdc5b4'), x: lx, y: base - 0.9, z: lz);
  const h = 18.0;
  for (var k = 0; k < 6; k++) {
    final r0 = 2.6 - (k / 6) * 0.8;
    final r1 = 2.6 - ((k + 1) / 6) * 0.8;
    putIn(c, cyl(r1, r0, h / 6, 14), k.isOdd ? red : white, x: lx, y: base + (k + 0.5) * (h / 6), z: lz);
  }
  putIn(c, cyl(2.4, 2.4, 0.3, 14), const Coat.plain('#3d405b'), x: lx, y: base + h + 0.15, z: lz);
  putIn(c, cyl(1.3, 1.3, 2, 12), const Coat.bulb('#fff3b0', 0.35), x: lx, y: base + h + 1.3, z: lz, shadow: false);
  putIn(c, cone(1.8, 1.6, 12), red, x: lx, y: base + h + 3.1, z: lz);
  putIn(c, sphere(0.25, 8, 6), const Coat.plain('#3d405b'), x: lx, y: base + h + 4.05, z: lz);
  kit.halos.add(Halo(at: vm.Vector3(lx, base + h + 1.3, lz), size: 9, color: '#fff3b0', ground: true));
  kit.colliders.add(
    Collider(minX: lx - 3.8, maxX: lx + 3.8, minZ: lz - 3.8, maxZ: lz + 3.8, bottom: G - 1, top: G + 30),
  );
  final col = <double>[];
  final cone0 = coloured(_beamCone(col), col);
  final cones = [
    for (final s in const [-1, 1])
      Clump()..add(cone0, const Coat.beam('#fff3b8'), rot: eulerQ(0, 0, (s * math.pi) / 2), shadow: false),
  ];
  return (boats: boats, beam: Beam(lx, base + h + 1.3, lz, cones));
}
