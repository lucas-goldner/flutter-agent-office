// The farm on the way out of town (world/scenic/farm.ts): its fields, the hay, the cows in their
// pasture, the barn and the silo, and the windmill.

import 'dart:math' as math;

import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../office/geo.dart' show Shape2;
import '../office/outside.dart' show Halo;
import 'kit.dart';

/// The farm. Returns the windmill's sails, to turn (about z, at their hub).
Clump buildFarm(ScenicKit kit) {
  final rand = kit.rand;
  final f = kit.of(Stretch.farm);
  // Fields of crops in rows, and a fence round the pasture.
  const crops = [Painted.wheat, Painted.greens];
  for (var k = 0; k < Farm.fields.length; k++) {
    final b = Farm.fields[k];
    final w = b.maxX - b.minX, d = b.maxZ - b.minZ;
    kit.root.add(
      Loose(
        flatPlane(w, d, w / 2.4, 1),
        Coat.flat('#ffffff', canvas: crops[k]),
        at: vm.Matrix4.translationValues((b.minX + b.maxX) / 2, G - 0.02, (b.minZ + b.maxZ) / 2),
        seen: Seen(b.minX, b.maxX, b.minZ, b.maxZ),
      ),
    );
    kit.take((b.minX + b.maxX) / 2, (b.minZ + b.maxZ) / 2, math.sqrt(w * w + d * d) / 2);
  }
  // Hay bales rolled up in the wheat.
  const hay = Coat.plain('#e9c46a');
  final bale = moved(cyl(0.85, 0.85, 1.3, 12), vm.Matrix4.rotationZ(math.pi / 2));
  final wheat = Farm.fields[0];
  for (var k = 0; k < 14; k++) {
    final x = wheat.minX + 4 + rand() * (wheat.maxX - wheat.minX - 8);
    final z = wheat.minZ + 4 + rand() * (wheat.maxZ - wheat.minZ - 8);
    putIn(f, bale, hay, x: x, y: G + 0.85, z: z, rot: yawQ(rand() * math.pi));
    kit.trunk(x, z, 0.8, 1.7);
  }
  const p = Farm.pasture;
  const rail = Coat.plain('#a47148');
  void fence(double x0, double z0, double x1, double z1) {
    final len = math.sqrt(math.pow(x1 - x0, 2) + math.pow(z1 - z0, 2));
    final n = (len / 3).ceil();
    for (var k = 0; k <= n; k++) {
      putIn(f, box(0.14, 1.2, 0.14), rail, x: x0 + ((x1 - x0) * k) / n, y: G + 0.6, z: z0 + ((z1 - z0) * k) / n);
    }
    for (final y in const [0.55, 1.0]) {
      putIn(
        f,
        box(0.06, 0.1, len),
        rail,
        x: (x0 + x1) / 2,
        y: G + y,
        z: (z0 + z1) / 2,
        rot: yawQ(math.atan2(x1 - x0, z1 - z0)),
      );
    }
    kit.colliders.add(
      Collider(
        minX: math.min(x0, x1) - 0.1,
        maxX: math.max(x0, x1) + 0.1,
        minZ: math.min(z0, z1) - 0.1,
        maxZ: math.max(z0, z1) + 0.1,
        bottom: G,
        top: G + 1.2,
        fence: true,
      ),
    );
  }

  fence(p.minX, p.minZ, p.maxX, p.minZ);
  fence(p.maxX, p.minZ, p.maxX, p.maxZ);
  fence(p.maxX, p.maxZ, p.minX, p.maxZ);
  fence(p.minX, p.maxZ, p.minX, p.minZ + 5);
  kit.take((p.minX + p.maxX) / 2, (p.minZ + p.maxZ) / 2, 22);
  // Cows, grazing.
  const white = Coat.plain('#f8f9fa');
  const black = Coat.plain('#22223b');
  const pink = Coat.plain('#ffb4a2');
  for (var k = 0; k < 6; k++) {
    final cow = Clump();
    cow.add(box(1.0, 0.85, 1.9), white, y: 1.15);
    cow.add(box(1.02, 0.5, 0.6), black, y: 1.25, z: 0.25);
    cow.add(box(0.6, 0.4, 0.5), black, x: 0.22, y: 1.35, z: -0.55);
    final head = Clump(y: 1.25, z: 1.05)..rotation = eulerQ(k.isOdd ? 0.7 : 0.1);
    head.add(box(0.55, 0.55, 0.65), white, z: 0.25);
    head.add(box(0.5, 0.3, 0.2), pink, y: -0.12, z: 0.62);
    for (final sx in const [-1, 1]) {
      head.add(box(0.08, 0.2, 0.08), const Coat.plain('#fefae0'), x: sx * 0.2, y: 0.36, z: 0.1);
    }
    cow.addClump(head);
    for (final (lx, lz) in const [(0.35, 0.7), (-0.35, 0.7), (0.35, -0.7), (-0.35, -0.7)]) {
      cow.add(box(0.2, 0.75, 0.2), white, x: lx, y: 0.37, z: lz);
    }
    final x = p.minX + 5 + rand() * (p.maxX - p.minX - 10);
    final z = p.minZ + 4 + rand() * (p.maxZ - p.minZ - 8);
    cow
      ..position = vm.Vector3(x, G, z)
      ..turn(rand() * math.pi * 2);
    f.add(cow);
    kit.colliders.add(Collider(minX: x - 1, maxX: x + 1, minZ: z - 1, maxZ: z + 1, bottom: G, top: G + 1.6));
  }
  // The barn: red, a gable roof, white trim and a big X-braced door facing the road.
  final bx = Farm.barn.x, bz = Farm.barn.z, bRot = Farm.barn.rotY;
  final barn = Clump(x: Farm.barn.x, y: G, z: Farm.barn.z)..turn(Farm.barn.rotY);
  barn.add(box(10, 5.5, 14), const Coat.plain('#b23a48'), y: 2.75);
  final gable = Shape2()
    ..moveTo(-5.7, 0)
    ..lineTo(5.7, 0)
    ..lineTo(0, 3.8);
  barn.add(moved(shapeMesh(gable, depth: 14), vm.Matrix4.translationValues(0, 5.5, -7)), const Coat.plain('#fefae0'));
  const roof = Coat.plain('#5c4d4d');
  for (final sx in const [-1, 1]) {
    barn.add(box(6.9, 0.25, 15), roof, x: sx * 2.85, y: 7.45, rot: eulerQ(0, 0, -sx * math.atan2(3.8, 5.7)));
  }
  const trim = Coat.plain('#fefae0');
  barn.add(box(4.2, 4.3, 0.12), const Coat.plain('#8d2b35'), y: 2.15, z: -7.02);
  for (final s in const [-1, 1]) {
    barn.add(box(0.22, 5.8, 0.1), trim, y: 2.15, z: -7.1, rot: eulerQ(0, 0, s * math.atan2(4.2, 4.3)));
  }
  barn.add(box(4.6, 0.25, 0.14), trim, y: 4.4, z: -7.08);
  barn.add(box(1.8, 1.4, 0.12), trim, y: 6.4, z: -7.05);
  barn.add(box(1.3, 0.95, 0.14), const Coat.plain('#3d2b1f'), y: 6.4, z: -7.1);
  f.add(barn);
  final lampAt = yawQ(bRot).rotated(vm.Vector3(0, 4.9, -7.25))..add(vm.Vector3(bx, G, bz));
  putIn(f, sphere(0.2, 10, 8), const Coat.bulb('#ffd89a', 0.1), x: lampAt.x, y: lampAt.y, z: lampAt.z, shadow: false);
  kit.halos.add(Halo(at: lampAt, size: 1.4, color: '#ffd89a', ground: true));
  kit.colliders.add(Collider(minX: bx - 7, maxX: bx + 7, minZ: bz - 7, maxZ: bz + 7, bottom: G, top: G + 9));
  kit.take(bx, bz, 11);
  // The silo beside it.
  const s = Farm.silo;
  putIn(kit.silo, cyl(3, 3, 13, 16), const Coat.plain('#cfd2d6'), x: s.x, y: G + 6.5, z: s.z);
  for (final y in const [3.0, 6.5, 10.0]) {
    putIn(kit.silo, cyl(3.05, 3.05, 0.25, 16), const Coat.plain('#8d99ae'), x: s.x, y: G + y, z: s.z, shadow: false);
  }
  putIn(kit.silo, sphere(3.05, 16, 6, math.pi / 2), const Coat.plain('#8d99ae'), x: s.x, y: G + 13, z: s.z);
  kit.colliders.add(Collider(minX: s.x - 3, maxX: s.x + 3, minZ: s.z - 3, maxZ: s.z + 3, bottom: G, top: G + 16));
  kit.take(s.x, s.z, 6);

  // The windmill, north of the street, its sails turning (see Scenic.update).
  const w = Farm.windmill;
  final mill = kit.mill;
  putIn(mill, cyl(2.2, 3.4, 12, 8), const Coat.plain('#f1e9da'), x: w.x, y: G + 6, z: w.z);
  putIn(mill, cone(2.7, 2.8, 8), const Coat.plain('#8d5b4c'), x: w.x, y: G + 13.4, z: w.z);
  putIn(mill, box(1.2, 2, 0.12), const Coat.plain('#6f4e37'), x: w.x, y: G + 1, z: w.z + 3.1);
  putIn(
    mill,
    moved(cyl(0.35, 0.35, 1.4, 8), vm.Matrix4.rotationX(math.pi / 2)),
    const Coat.plain('#5c4033'),
    x: w.x,
    y: G + 12,
    z: w.z + 2.6,
  );
  const cloth = Coat.plain('#fefae0');
  const frame = Coat.plain('#6f4e37');
  final sails = Clump(x: w.x, y: G + 12, z: w.z + 3.35);
  for (var k = 0; k < 4; k++) {
    final arm = Clump()..rotation = eulerQ(0, 0, (k * math.pi) / 2);
    arm.add(box(0.22, 8.5, 0.18), frame, y: 4.4);
    arm.add(box(1.5, 6.4, 0.08), cloth, x: 0.85, y: 5.2, z: -0.05);
    sails.addClump(arm);
  }
  kit.colliders.add(Collider(minX: w.x - 3, maxX: w.x + 3, minZ: w.z - 3, maxZ: w.z + 3, bottom: G, top: G + 14));
  kit.take(w.x, w.z, 7);
  return sails;
}
