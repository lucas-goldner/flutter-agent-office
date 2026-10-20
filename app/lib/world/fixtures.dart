// The fixtures on a map of its own (the castle, the space station, or one of yours): the 🏗️ build
// tower the office has, where the map's `fixtures` put it (office_shared's maps). A stand with the
// thing on top and its sign over it, in the way like a lectern; walk up and press E (or click its tag
// on the 👾 2D map) and it opens what the office's own does (the controller's _interact goes by the kind).

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'collider.dart';
import 'office/geo.dart';
import 'office/parts.dart' show tc;
import 'text.dart';
import 'toon.dart';
import 'world.dart';

/// What each fixture is to use, and what its sign says.
const Map<FixtureKey, (InteractKind, String)> fixtureKinds = {FixtureKey.build: (InteractKind.build, '🏗️ Builds')};

/// The thing you use at [f], a metre in front of it.
Interactable fixtureInteractable(FixtureKey k, FixturePlan f) {
  final (x, z) = fixtureFront(f);
  return Interactable(kind: fixtureKinds[k]!.$1, x: x, z: z, radius: 0.9);
}

/// What's in the way at [f]: its stand, as the map's plan has it (planMap).
Collider fixtureCollider(FixturePlan f) {
  final corners = [
    for (final t in const [-1, 1])
      for (final s in const [-0.3, 0.3])
        (
          f.x + math.cos(f.rotY) * t * 0.4 + math.sin(f.rotY) * s,
          f.z - math.sin(f.rotY) * t * 0.4 + math.cos(f.rotY) * s,
        ),
  ];
  return Collider(
    minX: corners.map((q) => q.$1).reduce(math.min),
    maxX: corners.map((q) => q.$1).reduce(math.max),
    minZ: corners.map((q) => q.$2).reduce(math.min),
    maxZ: corners.map((q) => q.$2).reduce(math.max),
    top: 1.2,
    fence: true,
  );
}

/// Puts [w]'s plan's fixtures up in it: their stands, what's in the way and what you use. The castle's
/// are oak with parchment signs, the station's metal with its own.
void addFixtures(World w) {
  final castle = w.plan.style == PlanStyle.castle;
  final base = tc(castle ? '#6b4526' : '#56627a');
  final trim = tc(castle ? '#3b2618' : '#27313f');
  final sign = TextOpts(bg: castle ? '#efe3c2' : '#dfe5ee', color: castle ? '#3b2618' : '#1b2330', size: 56);
  for (final MapEntry(key: k, value: f) in w.plan.fixtures.entries) {
    final g = Node(name: 'fixture:${k.wire}')
      ..position = vm.Vector3(f.x, 0, f.z)
      ..rotation = yaw(f.rotY);
    // The stand, its front (where you use it from) toward -z.
    g.add(mesh(box(0.8, 0.9, 0.6), base, 0, 0.45, 0));
    g.add(mesh(box(0.86, 0.06, 0.66), trim, 0, 0.93, 0, false));
    switch (k) {
      case FixtureKey.build:
        // A little rack, and its stack light on top.
        g.add(mesh(box(0.4, 0.9, 0.4), tc('#2b2d42'), 0, 1.41, 0.05));
        for (final (i, c) in const ['#e63946', '#ffd166', '#2a9d8f'].indexed) {
          g.add(mesh(box(0.2, 0.12, 0.2), tc(c, emissive: c), 0, 1.98 + i * 0.14, 0.05, false));
        }
    }
    g.add(
      textPlane(fixtureKinds[k]!.$2, sign)
        ..position = vm.Vector3(0, 2.6, -0.05)
        ..rotation = yaw(math.pi)
        ..scale = vm.Vector3.all(0.6),
    );
    w.group.add(g);
    w.colliders.add(fixtureCollider(f));
    final it = fixtureInteractable(k, f);
    w.interactables.add(it);
    tagInteract(g, it);
  }
}
