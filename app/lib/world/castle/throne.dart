// The throne of iron blades, and the dais it stands on. A port of world/castle/throne.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart' show MapPlan, ThroneSize;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../geo.dart' as g3;
import '../office/geo.dart' show cyl, sphere, yaw;
import '../toon.dart';
import 'kit.dart';

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

final Geometry _tip = g3
    .coneData(0.053, 0.13, 4)
    .transform(vm.Matrix4.diagonal3Values(1, 1, 0.25) * vm.Matrix4.rotationY(math.pi / 4) as vm.Matrix4)
    .build();

/// A sword, point up, [len] long from its guard to its tip, its hilt below the guard.
void _sword(Node g, double len, Mats mats, bool rust) {
  final steel = rust ? tc('#6f5a4e') : tc('#7f8791');
  g.add(_m(g3.box(0.075, len, 0.016), steel, 0, len / 2, 0, false));
  g.add(_m(_tip, steel, 0, len + 0.065, 0, false));
  g.add(_m(g3.box(0.3, 0.04, 0.045), mats.iron, 0, 0, 0, false));
  g.add(_m(cyl(0.022, 0.022, 0.18, 5), mats.iron, 0, -0.1, 0, false));
  g.add(_m(sphere(0.035, 6, 5), mats.iron, 0, -0.2, 0, false));
}

/// The throne of iron blades: an iron seat and back, and a couple of hundred swords welded round it,
/// fanning out behind in a jagged crown, bristling from the arms and spilling off the base. Faces +z.
Node _ironThrone(Mats mats) {
  final g = Node(name: 'throne');
  final rand = seeded(1234);
  g.add(_m(g3.box(1.9, 0.36, 1.7), mats.iron, 0, 0.18, -0.1));
  g.add(_m(g3.box(1.3, 0.32, 1.1), mats.iron, 0, 0.52, 0));
  g.add(_m(roundedBox(1.08, 0.1, 0.92, 0.05), mats.velvet, 0, 0.71, 0.05));
  g.add(_m(g3.box(1.4, 1.9, 0.3), mats.iron, 0, 1.6, -0.55));
  g.add(_m(roundedBox(0.95, 1.1, 0.08, 0.05), mats.velvet, 0, 1.3, -0.38));
  Node sword(double len, bool rust) {
    final s = Node(name: 'sword');
    _sword(s, len, mats, rust);
    return s;
  }

  for (final sx in const [-1, 1]) {
    g.add(_m(g3.box(0.2, 0.42, 1.1), mats.iron, sx * 0.72, 0.9, 0));
    // Blades bristling forward off the ends of the arms, and up and out along them.
    for (var i = 0; i < 5; i++) {
      final s = sword(0.45 + rand() * 0.35, rand() < 0.2);
      s.position = vm.Vector3(sx * (0.72 + (rand() - 0.5) * 0.12), 0.95 + rand() * 0.15, 0.45 - i * 0.2);
      s.rotation = g3.euler(math.pi / 2 - 0.5 - rand() * 0.4, 0, sx * (0.5 + rand() * 0.6));
      g.add(s);
    }
  }
  // The crown of blades behind the back: fanning out from behind the seat, longest in the middle.
  for (var layer = 0; layer < 4; layer++) {
    final n = 30 - layer * 5;
    for (var i = 0; i < n; i++) {
      final a = -1.45 + 2.9 * (i + rand() * 0.6) / n;
      final len = 1.1 + 2.7 * math.pow(math.cos(a), 2) - layer * 0.35 + rand() * 0.55;
      final s = sword(len, rand() < 0.15);
      s.position = vm.Vector3(math.sin(a) * 0.35, 1.25 + math.cos(a) * 0.45, -0.72 - layer * 0.1);
      s.rotation = g3.euler(-0.12 - layer * 0.08 + (rand() - 0.5) * 0.1, (rand() - 0.5) * 0.4, -a);
      g.add(s);
    }
  }
  // Swords spilling off the base in every direction but the front, points out and down.
  for (var i = 0; i < 30; i++) {
    final a = math.pi * 0.35 + rand() * math.pi * 1.3;
    final s = sword(0.5 + rand() * 0.5, rand() < 0.3);
    s.position = vm.Vector3(math.sin(a) * 0.85, 0.2 + rand() * 0.2, -0.1 + math.cos(a) * 0.75);
    s.rotation = g3.euler(0, a, math.pi / 2 - 0.2 - rand() * 0.5) * yaw(math.pi / 2);
    g.add(s);
  }
  // And a few down the front of the seat.
  for (var i = 0; i < 6; i++) {
    final s = sword(0.35 + rand() * 0.2, false);
    s.position = vm.Vector3(-0.5 + i * 0.2, 0.45, 0.56);
    s.rotation = g3.euler(math.pi / 2 + 0.9, 0, (rand() - 0.5) * 0.4);
    g.add(s);
  }
  return mergeByMaterial(g);
}

/// The dais at the throne's end of the hall, its steps and runner, and the throne of blades on it.
/// Returns somewhere to sit.
Interactable? buildDais(Kit kit, MapPlan plan) {
  final t = plan.throne;
  final dais = plan.dais;
  if (t == null || dais == null) return null;
  final m = kit.mats;
  final g = Node(name: 'dais')
    ..position = vm.Vector3(t.x, 0, t.z)
    ..rotation = yaw(t.rotY);
  // It runs 2.4 m in front of the throne (the rest behind), with its steps down from there.
  const front = 2.4;
  const stepD = 0.7;
  final top = dais.height;
  (double, double) at(double lx, double lz) =>
      (t.x + math.cos(t.rotY) * lx + math.sin(t.rotY) * lz, t.z - math.sin(t.rotY) * lx + math.cos(t.rotY) * lz);
  g.add(_m(g3.box(dais.width, top, dais.depth), m.stoneDark, 0, top / 2, front - dais.depth / 2));
  g.add(_m(g3.box(dais.width + 0.06, 0.1, 0.12), m.gold, 0, top - 0.04, front, false));
  final (cx, cz) = at(0, front - dais.depth / 2);
  collide(kit, cx, cz, dais.width, dais.depth, t.rotY, top);
  for (var k = 1; k <= dais.steps; k++) {
    final y = top * (dais.steps + 1 - k) / (dais.steps + 1);
    final lz = front + (k - 0.5) * stepD;
    g.add(_m(g3.box(dais.width - k * 0.4, y, stepD), m.stoneDark, 0, y / 2, lz));
    final (sx, sz) = at(0, lz);
    collide(kit, sx, sz, dais.width - k * 0.4, stepD, t.rotY, y);
    g.add(_m(g3.box(2.6, 0.03, stepD), m.carpet, 0, y + 0.012, lz, false));
  }
  // A runner up the dais to the throne.
  g.add(_m(g3.box(2.6, 0.03, front + 0.2), m.carpet, 0, top + 0.012, front / 2 - 0.1, false));
  for (final sx in const [-1, 1]) {
    g.add(
      _m(
        g3.box(0.12, 0.035, front + dais.steps * stepD),
        m.gold,
        sx * 1.2,
        top + 0.014,
        (front + dais.steps * stepD) / 2 - 0.2,
        false,
      ),
    );
  }
  final iron = _ironThrone(m)..position = vm.Vector3(0, top, 0);
  g.add(iron);
  kit.group.add(g);
  collide(
    kit,
    t.x - math.sin(t.rotY) * 0.2,
    t.z - math.cos(t.rotY) * 0.2,
    ThroneSize.width,
    ThroneSize.depth,
    t.rotY,
    99,
  );
  final seat = Interactable(kind: InteractKind.seat, seatId: t.id, x: t.x, y: t.y, z: t.z, radius: 1.7);
  tagInteract(iron, seat);
  kit.interactables.add(seat);
  return seat;
}
