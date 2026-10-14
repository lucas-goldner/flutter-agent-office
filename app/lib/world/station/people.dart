// The station's people who aren't workers: the First Officer, who brings new ones aboard, and
// Security, who sees them to the airlock when they're sent home. A port of world/station/people.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/avatar.dart' show Look;
import 'package:vector_math/vector_math.dart' as vm;

import '../character.dart';
import '../collider.dart';
import '../geo.dart' as g3;
import '../labels.dart';
import '../office/geo.dart' show cyl, yaw;
import '../toon.dart';
import '../world.dart' show Escort, Herald;
import 'kit.dart';

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

final Material _gold = tc('#e0b33a');

/// A slice of a cylinder [h] tall and [r] round, from [start] for [length] radians round y (three's
/// thetaStart and thetaLength: 0 is +z): its top, its bottom and, unless [open], its rim.
Geometry _slice(double r, double h, double start, double length, int seg, {bool caps = true}) {
  final g = g3.GeoData();
  final y0 = -h / 2, y1 = h / 2;
  final rim = <(int, int)>[];
  for (var i = 0; i <= seg; i++) {
    final a = start + length * i / seg;
    final s = math.sin(a), c = math.cos(a);
    rim.add((g.vertex(r * s, y1, r * c, s, 0, c), g.vertex(r * s, y0, r * c, s, 0, c)));
  }
  for (var i = 0; i < seg; i++) {
    final (a, b) = rim[i];
    final (c, d) = rim[i + 1];
    g.tri(a, b, d);
    g.tri(a, d, c);
  }
  if (caps) {
    for (final (y, ny) in [(y1, 1.0), (y0, -1.0)]) {
      final mid = g.vertex(0, y, 0, 0, ny, 0);
      final ring = [
        for (var i = 0; i <= seg; i++)
          g.vertex(r * math.sin(start + length * i / seg), y, r * math.cos(start + length * i / seg), 0, ny, 0),
      ];
      for (var i = 0; i < seg; i++) {
        g.tri(mid, ring[i], ring[i + 1]);
      }
    }
  }
  return g.build();
}

/// The herald (the First Officer), in a uniform jacket with gold on its shoulders and a peaked cap,
/// where the plan has them.
Herald? buildHerald(Kit kit, LabelHub labels) {
  final hd = kit.plan.herald;
  if (hd == null) return null;
  const navy = '#1d3557';
  final person = Person(hd.name, navy, const Look(skin: 1, hair: 2, style: 1), labels);
  final y = kit.floorAt(hd.x, hd.z);
  person.root
    ..position = vm.Vector3(hd.x, y, hd.z)
    ..rotation = yaw(hd.rotY);
  person.setLabel(hd.name, null);
  person.setDoing(hd.says);
  person.wear(_m(g3.lathe(const [(0.31, 0.34), (0.3, 0.7), (0.28, 1.0)], 20), tc(navy)), 'body');
  for (final sx in const [-1, 1]) {
    person.wear(_m(g3.box(0.16, 0.035, 0.12), _gold, sx * 0.24, 1.0, 0, false), 'body');
  }
  // A delta on the chest, and a stripe down the front.
  person.wear(_m(g3.cone(0.05, 0.11, 3), _gold, 0.1, 0.84, 0.285, false), 'body');
  person.wear(_m(g3.box(0.03, 0.5, 0.02), _gold, 0, 0.62, 0.3, false), 'body');
  final cap = Node(name: 'cap')
    ..add(_m(cyl(0.33, 0.31, 0.14, 20), tc(navy), 0, 0.3, 0))
    ..add(_m(cyl(0.34, 0.34, 0.03, 20), kit.mats.white, 0, 0.385, 0, false))
    ..add(_m(_slice(0.3, 0.025, -0.9, 1.8, 16), kit.mats.black, 0, 0.235, 0.12, false))
    ..add(_m(g3.box(0.1, 0.06, 0.02), _gold, 0, 0.31, 0.325, false));
  person.wear(cap, 'head');
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

/// One of Security (the map's escort, see MapPlan.sendHome): a helmet with a lit visor, armour in
/// [color] over the shoulders and chest, and a stun baton in the left hand, so the right's free to
/// take a worker by the shoulder.
Person _guard(Mats mats, String name, String color, LabelHub labels) {
  final person = Person(name, color, const Look(skin: 3, hair: 1, style: 6), labels);
  person.setLabel(name, null);
  final plate = tc(color);
  final visor = lit('#ff4d4d')..doubleSided = true;
  final helm = Node(name: 'helm')
    ..add(_m(g3.sphere(0.38, 18, 12, 0, math.pi * 2, 0, math.pi * 0.62), plate, 0, 0.02, 0))
    // The visor: a band of light across where its eyes are.
    ..add(_m(_slice(0.385, 0.1, -1.0, 2.0, 20, caps: false), visor, 0, 0.04, 0, false))
    ..add(_m(g3.box(0.05, 0.14, 0.3), mats.metalDark, 0, 0.38, -0.05, false));
  person.wear(helm, 'head');
  person.wear(_m(g3.lathe(const [(0.33, 0.42), (0.32, 0.7), (0.3, 1.0)], 18), plate), 'body');
  for (final sx in const [-1, 1]) {
    person.wear(_m(g3.sphere(0.14, 10, 8), mats.metalDark, sx * 0.3, 0.98, 0), 'body');
  }
  person.wear(_m(g3.torusData(0.3, 0.045, 6, 18).rotateX(math.pi / 2).build(), mats.black, 0, 0.5, 0, false), 'body');
  person.wear(_m(g3.box(0.2, 0.07, 0.03), lit('#ffd24d'), 0, 0.82, 0.3, false), 'body');
  final baton = Node(name: 'baton')
    ..add(_m(cyl(0.03, 0.03, 0.7, 8), mats.black, 0, 0.1, 0))
    ..add(_m(cyl(0.038, 0.038, 0.22, 8), lit('#7fd8ff'), 0, 0.42, 0, false))
    ..position = vm.Vector3(0, -0.36, 0.04)
    ..rotation = g3.euler(0.5, 0);
  person.wear(baton, 'offhand');
  return person;
}

/// The map's escort (MapPlan.sendHome), on watch at its post, and how to call out another when it's busy.
Escort? buildEscort(Kit kit, LabelHub labels) {
  final e = kit.plan.sendHome?.escort;
  if (e == null) return null;
  Person make() => _guard(kit.mats, e.name, e.color, labels);
  final person = make();
  person.root
    ..position = vm.Vector3(e.post.x, e.post.y, e.post.z)
    ..rotation = yaw(e.post.rotY);
  kit.group.add(person.root);
  return (post: e.post, below: e.below, guard: person, make: make);
}
