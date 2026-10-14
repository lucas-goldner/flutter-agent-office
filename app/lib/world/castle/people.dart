// The castle's people who aren't workers: the herald who sends workers out, and the Kingsguard who
// takes them down to the dungeon when they're sent home. A port of world/castle/people.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/avatar.dart' show Look;
import 'package:office_shared/maps/maps.dart' show MapPlan;
import 'package:vector_math/vector_math.dart' as vm;

import '../character.dart';
import '../collider.dart';
import '../geo.dart' as g3;
import '../labels.dart';
import '../office/geo.dart' show cone, cyl, sphere, yaw;
import '../toon.dart';
import '../world.dart' show Escort, Herald;
import 'kit.dart';

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

/// The herald (the Hand of the King), in a robe of office with a gold chain, where the plan has him.
Herald? buildHerald(Kit kit, MapPlan plan, LabelHub labels) {
  final hd = plan.herald;
  if (hd == null) return null;
  final person = Person(hd.name, '#1f4d3a', const Look(skin: 2, hair: 5, style: 0), labels);
  final y = kit.floorAt(hd.x, hd.z);
  person.root
    ..position = vm.Vector3(hd.x, y, hd.z)
    ..rotation = yaw(hd.rotY);
  person.setLabel(hd.name, null);
  person.setDoing(hd.says);
  person.root.add(_m(g3.lathe(const [(0.36, 0.02), (0.3, 0.5), (0.27, 0.95)], 20), tc('#1f4d3a')));
  person.root.add(
    _m(g3.torus(0.24, 0.025, 6, 20), kit.mats.gold, 0, 0.98, 0.04, false)..rotation = g3.euler(math.pi / 2 - 0.35, 0),
  );
  // The pin of his office.
  person.root.add(_m(g3.box(0.1, 0.12, 0.03), kit.mats.gold, 0.1, 0.86, 0.27, false));
  kit.group.add(person.root);
  final it = Interactable(
    kind: InteractKind.herald,
    x: hd.x + math.sin(hd.rotY) * 0.9,
    y: y == 0 ? null : y,
    z: hd.z + math.cos(hd.rotY) * 0.9,
    radius: 1.9,
  );
  tagInteract(person.root, it);
  kit.interactables.add(it);
  kit.colliders.add(Collider(minX: hd.x - 0.35, maxX: hd.x + 0.35, minZ: hd.z - 0.35, maxZ: hd.z + 0.35, top: 99));
  return (person: person, interactable: it);
}

/// One of the Kingsguard (the map's escort, see MapPlan.sendHome): a kettle helm, a surcoat in [color]
/// over mail, and a halberd in the left hand, so the right's free to take a worker by the shoulder.
Person _guard(Mats mats, String name, String color, LabelHub labels) {
  final person = Person(name, color, const Look(skin: 3, hair: 1, style: 6), labels);
  person.setLabel(name, null);
  final helm = Node(name: 'helm')
    ..add(_m(g3.sphere(0.37, 16, 10, 0, math.pi * 2, 0, math.pi / 2), mats.steel, 0, 0.04, 0))
    ..add(_m(cyl(0.5, 0.52, 0.04, 20), mats.steel, 0, 0.06, 0))
    ..add(_m(sphere(0.05, 8, 6), mats.steel, 0, 0.41, 0, false));
  person.wear(helm, 'head');
  person.wear(_m(g3.lathe(const [(0.33, 0.36), (0.3, 0.7), (0.28, 1.0)], 18), tc(color)), 'body');
  person.wear(_m(g3.torusData(0.29, 0.05, 6, 18).rotateX(math.pi / 2).build(), mats.gold, 0, 0.66, 0, false), 'body');
  // The realm's crown on the chest.
  person.wear(_m(g3.box(0.14, 0.1, 0.03), mats.gold, 0, 0.84, 0.29, false), 'body');
  final halberd = Node(name: 'halberd')
    ..add(_m(cyl(0.025, 0.025, 2.1, 6), mats.woodDark, 0, 0.35, 0))
    ..add(_m(cone(0.035, 0.28, 6), mats.steel, 0, 1.54, 0))
    ..add(_m(g3.box(0.03, 0.26, 0.22), mats.steel, 0, 1.22, 0.12))
    ..add(_m(g3.box(0.025, 0.08, 0.1), mats.steel, 0, 1.22, -0.08, false))
    ..position = vm.Vector3(0, -0.38, 0.02)
    ..rotation = g3.euler(0.08, 0);
  person.wear(halberd, 'offhand');
  return person;
}

/// The map's escort (MapPlan.sendHome), on watch at its post, and how to call out another when it's busy.
Escort? buildEscort(Kit kit, MapPlan plan, LabelHub labels) {
  final e = plan.sendHome?.escort;
  if (e == null) return null;
  Person make() => _guard(kit.mats, e.name, e.color, labels);
  final person = make();
  person.root
    ..position = vm.Vector3(e.post.x, e.post.y, e.post.z)
    ..rotation = yaw(e.post.rotY);
  kit.group.add(person.root);
  return (post: e.post, below: e.below, guard: person, make: make);
}
