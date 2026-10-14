// A worker locked up in a dungeon's cell (see Worker.setJailed): starving, then dead, then its bones.
// A port of world/character/worker-jail.ts.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'geo.dart';
import 'toon.dart';

/// What a worker's skin goes toward as it starves in a cell, and once it's dead.
const Color kStarved = Color(0xFFCFC7B2);
const Color kDead = Color(0xFF7D8A6A);

/// How far gone a worker locked in a cell is.
typedef Jailed = ({double thin, bool dead, double rot});

Material get _bone => toon(hex('#e9e1c9'));
Material get _socket => toon(hex('#241c16'));

/// What's left of a worker that has rotted away in a cell: a skull, a spine and ribs, a pelvis, and the
/// bones of its arms and feet, the size of the bean it was, in its body's space (forward is +z).
Node bones() {
  final g = Node(name: 'bones');
  void bone(vm.Vector3 a, vm.Vector3 b, [double r = 0.022]) {
    final along = b - a;
    g.add(
      mesh(capsule(r, along.length, 3, 6), _bone, (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        ..rotation = vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), along.normalized()),
    );
    for (final end in [a, b]) {
      g.add(mesh(sphere(r * 1.7, 6, 5), _bone, end.x, end.y, end.z, false));
    }
  }

  // The skull, its sockets and its grin.
  g.add(mesh(sphere(0.15, 14, 12), _bone, 0, 0.74, 0.02)..scale = vm.Vector3(1, 1.05, 0.95));
  for (final sx in const [-1, 1]) {
    g.add(mesh(sphere(0.042, 8, 6), _socket, sx * 0.06, 0.76, 0.14, false));
  }
  g.add(mesh(cone(0.018, 0.04, 3), _socket, 0, 0.7, 0.155, false));
  g.add(mesh(box(0.16, 0.05, 0.12), _bone, 0, 0.6, 0.05));
  for (var i = 0; i < 5; i++) {
    g.add(mesh(box(0.018, 0.03, 0.01), _socket, -0.05 + i * 0.025, 0.635, 0.113, false));
  }
  // The spine, the ribs round it, and the pelvis at the bottom.
  bone(vm.Vector3(0, 0.2, -0.06), vm.Vector3(0, 0.6, -0.04));
  for (var i = 0; i < 4; i++) {
    g.add(
      mesh(torus(0.12 - i * 0.012, 0.014, 5, 14, math.pi * 1.35), _bone, 0, 0.52 - i * 0.065, 0)
        ..rotation = euler(math.pi / 2, 0, -math.pi * 0.175 + math.pi / 2),
    );
  }
  g.add(mesh(torus(0.09, 0.025, 6, 12), _bone, 0, 0.2, 0)..rotation = euler(math.pi / 2.4, 0));
  // Arms hanging, and the feet stuck out in front.
  for (final sx in const [-1.0, 1.0]) {
    bone(vm.Vector3(sx * 0.16, 0.55, 0), vm.Vector3(sx * 0.26, 0.4, 0.06));
    bone(vm.Vector3(sx * 0.26, 0.4, 0.06), vm.Vector3(sx * 0.24, 0.26, 0.16));
    bone(vm.Vector3(sx * 0.07, 0.18, 0.02), vm.Vector3(sx * 0.12, 0.12, 0.24), 0.026);
  }
  g.visible = false;
  return g;
}

/// X for eyes, once it's dead: a cross over each, on its [body].
List<Node> crossedEyes(Node body) {
  final crosses = <Node>[];
  final ink = toon(hex('#1d1d1d'));
  for (final sx in const [-1, 1]) {
    for (final r in const [-1, 1]) {
      final bar = mesh(capsule(0.014, 0.1, 4, 6), ink, sx * 0.11, 0.7, 0.25, false)..rotation = euler(0, 0, r * 0.8);
      body.add(bar);
      crosses.add(bar);
    }
  }
  return crosses;
}
