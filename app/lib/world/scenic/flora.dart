// What grows along the loop (and the rocks), world/scenic/flora.ts: pines, leafy trees, palms and
// boulders, each standing on the street's level.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' show MeshData;
import 'package:vector_math/vector_math.dart' as vm;

import 'kit.dart';

const List<String> pines = ['#2d6a4f', '#40916c', '#1b4332', '#52796f'];
const List<String> leaves = ['#5fb760', '#3f8f45', '#6fcf6a', '#74a57f'];
const List<String> autumn = ['#f4a259', '#e76f51', '#e9c46a'];

/// A pine, feet at (x, z) on the street's level: three cones on a stubby trunk.
void pine(List<Clump> into, double x, double z, double s, String color, double turn) {
  final g = Clump(x: x, y: G, z: z);
  // No ends on the trunk or the cones: nobody sees under a pine.
  g.add(cyl(0.18, 0.26, 1.6, 6, true), const Coat.plain('#6f4e37'), y: 0.8);
  final leaf = Coat.plain(color);
  g.add(cone(1.9, 3.2, 7, true), leaf, y: 2.7);
  g.add(cone(1.45, 2.6, 7, true), leaf, y: 4.1);
  g.add(cone(0.95, 2.1, 7, true), leaf, y: 5.4);
  g.turn(turn);
  g.scale = vm.Vector3(s, s * (0.9 + (turn % 0.3)), s);
  into.add(g);
}

/// A leafy tree: a trunk and a couple of faceted blobs of leaves.
void leafy(List<Clump> into, double x, double z, double s, String color, double turn) {
  final g = Clump(x: x, y: G, z: z);
  g.add(cyl(0.2, 0.28, 2.1, 6, true), const Coat.plain('#8a5a3b'), y: 1.05);
  final leaf = Coat.plain(color);
  g.add(ico(1.7, 1), leaf, y: 3.2);
  g.add(ico(1.15, 1), leaf, x: 0.8, y: 3.9, z: 0.35);
  g.turn(turn);
  g.scale = vm.Vector3.all(s);
  into.add(g);
}

final MeshData _frond = moved(
  cone(0.42, 3, 4),
  vm.Matrix4.translationValues(0, 0, 1.5) * vm.Matrix4.diagonal3Values(1, 0.22, 1) * vm.Matrix4.rotationX(math.pi / 2)
      as vm.Matrix4,
);

/// A palm, leaning a little: a trunk in segments, fronds drooping all round, and coconuts.
void palm(List<Clump> into, double x, double z, double s, double turn) {
  final g = Clump(x: x, y: G, z: z);
  const bark = Coat.plain('#b08968');
  var lean = 0.0;
  var y = 0.0;
  for (var i = 0; i < 6; i++) {
    g.add(
      cyl(0.15 - i * 0.008, 0.2 - i * 0.008, 1.15, 6),
      bark,
      x: lean,
      y: y + 0.55,
      rot: eulerQ(0, 0, -0.05 - i * 0.03),
    );
    lean += 0.08 + i * 0.045;
    y += 1.08;
  }
  const frond = Coat.plain('#52b788');
  for (var k = 0; k < 8; k++) {
    final f = Clump(x: lean, y: y + 0.05)..turn((k / 8) * math.pi * 2);
    // A long leaf, widest near its stem and drooping to a point.
    f.add(_frond, frond, rot: eulerQ(0.35 + (k % 2) * 0.2));
    g.addClump(f);
  }
  for (var k = 0; k < 3; k++) {
    g.add(
      sphere(0.16, 6, 5),
      const Coat.plain('#7f5539'),
      x: lean + math.cos(k * 2.1) * 0.25,
      y: y - 0.15,
      z: math.sin(k * 2.1) * 0.25,
    );
  }
  g.turn(turn);
  g.scale = vm.Vector3.all(s);
  into.add(g);
}

final Map<double, MeshData> _boulders = {};

/// A boulder: a lumpy, faceted grey rock, half sunk in the ground.
void boulder(List<Clump> into, double x, double z, double r, double turn, [String color = '#9d99a8']) {
  final geo = _boulders[r] ??= () {
    final p = icosahedron(r, 0);
    for (var i = 1; i < p.length; i += 3) {
      p[i] *= 0.7;
    }
    return faceted(p);
  }();
  final c = Clump(x: x, y: G + r * 0.25, z: z)..rotation = eulerQ(turn * 0.3, turn, turn * 0.2);
  c.add(geo, Coat.plain(color));
  into.add(c);
}
