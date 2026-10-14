// Where everyone sits and stands: the long tables and their benches with a place at each for a
// worker, the board agents' lecterns, and the round table the meetings are held at. A port of
// world/castle/seats.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart' show DeskDef, Kiosk, StationKind, deskSeat, stationAgent;
import 'package:office_shared/maps/maps.dart' show Council, MapPlan, benchOut;
import 'package:office_shared/maps/props.dart' show boxFootprint;
import 'package:office_shared/nav.dart' show deskPoint;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../geo.dart' as g3;
import '../office/geo.dart' show cyl, planeXY, sphere, yaw;
import '../office/office.dart' show DeskView, Face;
import '../office/parts.dart' show vacancyMarker;
import '../text.dart';
import '../toon.dart';
import 'fire.dart';
import 'kit.dart';

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

/// The long tables and their benches, as the plan has them, with candles down the middle.
void buildTables(Kit kit, MapPlan plan) {
  final m = kit.mats;
  for (final t in plan.tables) {
    final g = Node(name: t.name)
      ..position = vm.Vector3(t.x, 0, t.z)
      ..rotation = yaw(t.rotY);
    // Along local z; the benches along its sides.
    g.add(_m(roundedBox(t.width, 0.1, t.length, 0.05), m.wood, 0, tableTop - 0.05, 0));
    g.add(_m(g3.box(0.16, 0.12, t.length - 0.8), m.woodDark, 0, 0.22, 0));
    final legs = math.max(2, (t.length / 3.2).round() + 1);
    for (var i = 0; i < legs; i++) {
      final lz = -t.length / 2 + 0.35 + i * (t.length - 0.7) / (legs - 1);
      g.add(_m(g3.box(t.width - 0.3, tableTop - 0.1, 0.12), m.woodDark, 0, (tableTop - 0.1) / 2, lz));
    }
    // Candles down the middle, between the places.
    for (var i = 0; i < t.seats - 1; i++) {
      final lz = (i + 1 - t.seats / 2) * (t.length / t.seats);
      g.add(_m(cyl(0.07, 0.09, 0.05, 8), m.iron, 0, tableTop + 0.025, lz, false));
      g.add(_m(cyl(0.035, 0.035, 0.22, 6), m.candle, 0, tableTop + 0.16, lz, false));
      flame(kit, g, 0, tableTop + 0.28, lz, 0.08);
    }
    for (final s in t.sides) {
      final bx = s * (t.width / 2 + benchOut);
      g.add(_m(roundedBox(0.44, 0.08, t.length - 0.2, 0.03), m.wood, bx, benchTop - 0.04, 0));
      for (var i = 0; i < legs; i++) {
        final lz = -t.length / 2 + 0.4 + i * (t.length - 0.8) / (legs - 1);
        g.add(_m(g3.box(0.34, benchTop - 0.08, 0.08), m.woodDark, bx, (benchTop - 0.08) / 2, lz));
      }
      collide(kit, t.x + math.cos(t.rotY) * bx, t.z - math.sin(t.rotY) * bx, 0.44, t.length - 0.2, t.rotY, benchTop);
    }
    kit.group.add(g);
    collide(kit, t.x, t.z, t.width, t.length, t.rotY, tableTop);
  }
}

/// A place at a table: its tome, the worker on the bench, a plate and a goblet, and the '+' while it's free.
({DeskView view, Interactable it}) placeSetting(Kit kit, DeskDef def, bool overflow) {
  final g = atDesk(def);
  final laptopAnchor = Node(name: 'laptop-anchor')
    ..position = vm.Vector3(0, tableTop, -0.02)
    ..scale = vm.Vector3.all(1.1);
  g.add(laptopAnchor);
  // On the bench, facing the table.
  final seatAnchor = Node(name: 'seat-anchor')
    ..position = vm.Vector3(0, benchTop - 0.08, 0.85)
    ..rotation = yaw(math.pi)
    ..scale = vm.Vector3.all(0.82);
  g.add(seatAnchor);
  // Up on the table beside the tome.
  final stage = Node(name: 'stage')..position = vm.Vector3(0.66, tableTop - 0.07, 0.12);
  g.add(stage);
  g.add(_m(cyl(0.16, 0.13, 0.02, 14), tc('#8d939c'), -0.62, tableTop + 0.01, 0.12, false));
  g.add(_m(cyl(0.045, 0.03, 0.14, 8), kit.mats.gold, -0.62, tableTop + 0.08, -0.12, false));
  final vacancy = vacancyMarker(1.35);
  g.add(vacancy);
  // An overflow seat is put away until they're all taken (see setBeanbags).
  g.visible = !overflow;
  final spot = deskSeat(def, 1.25);
  final it = Interactable(kind: InteractKind.desk, deskId: def.id, x: spot.x, z: spot.z, radius: 1.3, off: overflow);
  kit.interactables.add(it);
  tagInteract(g, it);
  kit.group.add(g);
  return (
    view: DeskView(
      def: def,
      group: g,
      laptopAnchor: laptopAnchor,
      seatAnchor: seatAnchor,
      stage: stage,
      chair: Node(name: 'chair'),
      vacancy: vacancy,
      vacancyY: 1.35,
    ),
    it: it,
  );
}

/// A board or a sign: a face the office paints a picture onto (see the controller's boards).
Face _face(double w, double h) {
  final mat = UnlitMaterial();
  return Face(mesh(planeXY(w, h), mat, 0, 0, 0, false), mat, w, h);
}

/// The round meeting table, its chairs, and the easel with the meeting's board and sign.
({Face? board, Face? sign}) buildCouncil(Kit kit, MapPlan plan) {
  final cp = plan.council;
  if (cp == null) return (board: null, sign: null);
  final m = kit.mats;
  final t = Node(name: 'council')..position = vm.Vector3(cp.x, 0, cp.z);
  t.add(_m(cyl(Council.radius, Council.radius, 0.1, 32), m.wood, 0, Council.height - 0.05, 0));
  t.add(
    _m(
      g3.torusData(Council.radius, 0.04, 6, 32).rotateX(math.pi / 2).build(),
      m.gold,
      0,
      Council.height - 0.05,
      0,
      false,
    ),
  );
  t.add(_m(cyl(0.18, 0.28, Council.height - 0.1, 10), m.woodDark, 0, (Council.height - 0.1) / 2, 0));
  t.add(_m(cyl(0.55, 0.6, 0.08, 14), m.woodDark, 0, 0.04, 0));
  // A map of the realm on the table.
  t.add(_m(cyl(0.55, 0.55, 0.004, 24), m.parchment, 0, Council.height + 0.006, 0, false));
  kit.group.add(t);
  // A square inside the round top, so its corners don't stick out past the edge.
  final r = Council.radius * math.sqrt1_2;
  kit.colliders.add(Collider(minX: cp.x - r, maxX: cp.x + r, minZ: cp.z - r, maxZ: cp.z + r, top: Council.height));
  final meeting = Interactable(kind: InteractKind.meeting, x: cp.x, z: cp.z, radius: 2.5);
  tagInteract(t, meeting);
  kit.interactables.add(meeting);
  for (final def in plan.meeting) {
    kit.desks[def.id] = _councilChair(kit, def);
  }
  // An easel behind the table, away from its head, with the meeting's board and how it's going.
  final easel = Node(name: 'easel')
    ..position = vm.Vector3(cp.x - math.sin(cp.rotY) * Council.easel, 0, cp.z - math.cos(cp.rotY) * Council.easel)
    ..rotation = yaw(cp.rotY);
  for (final sx in const [-1, 1]) {
    easel.add(_m(g3.box(0.1, 2.9, 0.1), m.woodDark, sx * 1.05, 1.42, 0)..rotation = g3.euler(0, 0, sx * -0.05));
  }
  easel.add(_m(g3.box(0.1, 2.5, 0.1), m.woodDark, 0, 1.2, -0.45));
  easel.add(_m(g3.box(2.5, 1.6, 0.08), m.woodDark, 0, 1.95, 0.02));
  final board = _face(2.3, 1.4);
  board.node.position = vm.Vector3(0, 1.95, 0.07);
  easel.add(board.node);
  final sign = _face(1.2, 0.34);
  sign.node.position = vm.Vector3(0, 0.92, 0.07);
  easel.add(_m(g3.box(1.3, 0.42, 0.06), m.woodDark, 0, 0.92, 0.02));
  easel.add(sign.node);
  easel.add(
    textPlane('🤝 The small council', const TextOpts(bg: '#efe3c2', size: 56))
      ..position = vm.Vector3(0, 2.98, 0.06)
      ..scale = vm.Vector3.all(0.62),
  );
  tagInteract(easel, meeting);
  kit.group.add(easel);
  final (minX, maxX, minZ, maxZ) = boxFootprint(easel.position.x, easel.position.z, 2.6, 0.5, cp.rotY);
  kit.colliders.add(Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, top: 99));
  return (board: board, sign: sign);
}

const Map<StationKind, String> _lecternSign = {
  StationKind.issues: '📜 Ask me',
  StationKind.pulls: '🔀 Ask me',
  StationKind.queue: '📋 Ask me',
};

/// A board agent's lectern (a scribe's desk): the agent stands behind it, as at the office's kiosk.
DeskView lectern(Kit kit, DeskDef def) {
  final kind = def.station!;
  final g = atDesk(def);
  final m = kit.mats;
  g.add(_m(g3.box(0.5, 0.06, 0.4), m.woodDark, 0, 0.03, 0));
  g.add(_m(g3.box(0.14, 0.95, 0.14), m.woodDark, 0, 0.5, 0));
  final top = Node(name: 'top')
    ..position = vm.Vector3(0, 1.0, 0)
    ..rotation = g3.euler(0.35, 0);
  top.add(_m(g3.box(Kiosk.width, 0.06, Kiosk.depth), m.wood));
  // An open book on it, its pages facing whoever walks up (-z, the room).
  for (final sx in const [-1, 1]) {
    top.add(
      _m(g3.box(0.28, 0.03, 0.36), m.parchment, sx * 0.15, 0.045, 0, false)..rotation = g3.euler(0, 0, sx * 0.08),
    );
  }
  top.add(_m(g3.box(0.02, 0.2, 0.02), tc('#f3ead2'), 0.3, 0.1, 0.15, false));
  g.add(top);
  // The agent's color on a cloth over the front, and a sign.
  g.add(_m(g3.box(0.42, 0.55, 0.02), tc(stationAgent[kind]!.color), 0, 0.62, -0.09, false));
  g.add(
    textPlane(_lecternSign[kind]!, const TextOpts(bg: '#efe3c2', size: 56))
      ..position = vm.Vector3(0, 0.62, -0.11)
      ..rotation = yaw(math.pi)
      ..scale = vm.Vector3.all(0.55),
  );
  final laptopAnchor = Node(name: 'laptop-anchor')..visible = false;
  g.add(laptopAnchor);
  // On its feet behind the lectern, facing it and the room beyond.
  Node stand() => Node(name: 'stand')
    ..position = vm.Vector3(0, -0.07 * 1.1, Kiosk.stand)
    ..rotation = yaw(math.pi)
    ..scale = vm.Vector3.all(1.1);
  final seatAnchor = stand();
  g.add(seatAnchor);
  final vacancy = Node(name: 'vacancy')..add(stand());
  g.add(vacancy);
  final stage = Node(name: 'stage')
    ..position = vm.Vector3(0, 1.0, 0)
    ..rotation = yaw(math.pi);
  g.add(stage);
  kit.group.add(g);
  final corners = [
    for (final t in const [-1, 1])
      for (final s in const [-0.25, Kiosk.stand + 0.35]) deskPoint(def, t * Kiosk.width / 2, s),
  ];
  kit.colliders.add(
    Collider(
      minX: corners.map((p) => p.$1).reduce(math.min),
      maxX: corners.map((p) => p.$1).reduce(math.max),
      minZ: corners.map((p) => p.$2).reduce(math.min),
      maxZ: corners.map((p) => p.$2).reduce(math.max),
      top: 1.5,
      fence: true,
    ),
  );
  final (fx, fz) = deskPoint(def, 0, -1);
  final it = Interactable(kind: InteractKind.station, deskId: def.id, x: fx, z: fz, radius: 1.3);
  kit.interactables.add(it);
  tagInteract(g, it);
  return DeskView(
    def: def,
    group: g,
    laptopAnchor: laptopAnchor,
    seatAnchor: seatAnchor,
    stage: stage,
    chair: Node(name: 'chair'),
    vacancy: vacancy,
    vacancyY: 0,
  );
}

/// A high-backed chair at the meeting table, with its tome on the table in front of it.
DeskView _councilChair(Kit kit, DeskDef def) {
  final g = atDesk(def);
  final m = kit.mats;
  final chair = Node(name: 'chair')..position = vm.Vector3(0, 0, 0.85);
  chair.add(_m(g3.box(0.6, 0.08, 0.56), m.woodDark, 0, 0.46, 0));
  chair.add(_m(roundedBox(0.52, 0.06, 0.48, 0.04), m.velvet, 0, 0.52, 0, false));
  chair.add(_m(g3.box(0.6, 1.25, 0.08), m.woodDark, 0, 1.1, 0.26));
  chair.add(_m(roundedBox(0.44, 0.7, 0.04, 0.04), m.velvet, 0, 1.05, 0.21, false));
  chair.add(_m(sphere(0.06, 8, 6), m.gold, -0.28, 1.76, 0.26, false));
  chair.add(_m(sphere(0.06, 8, 6), m.gold, 0.28, 1.76, 0.26, false));
  for (final sx in const [-1, 1]) {
    for (final sz in const [-1, 1]) {
      chair.add(_m(g3.box(0.07, 0.46, 0.07), m.woodDark, sx * 0.25, 0.23, sz * 0.22));
    }
  }
  g.add(chair);
  final laptopAnchor = Node(name: 'laptop-anchor')
    ..position = vm.Vector3(0, Council.height, Council.tome.z)
    ..scale = vm.Vector3.all(Council.tome.scale);
  g.add(laptopAnchor);
  final seatAnchor = Node(name: 'seat-anchor')
    ..position = vm.Vector3(0, 0.46, 0.85)
    ..rotation = yaw(math.pi)
    ..scale = vm.Vector3.all(0.82);
  g.add(seatAnchor);
  // A merge's dance party: up on its chair rather than the table, which the five tomes fill.
  final stage = Node(name: 'stage')..position = vm.Vector3(0, 0.48, 0.85);
  g.add(stage);
  final vacancy = vacancyMarker(1.45);
  g.add(vacancy);
  kit.group.add(g);
  final cx = def.x + math.sin(def.rotY) * 0.85, cz = def.z + math.cos(def.rotY) * 0.85;
  kit.colliders.add(Collider(minX: cx - 0.3, maxX: cx + 0.3, minZ: cz - 0.3, maxZ: cz + 0.3, top: 0.5));
  final spot = deskSeat(def, 1.5);
  final it = Interactable(kind: InteractKind.desk, deskId: def.id, x: spot.x, z: spot.z, radius: 1.1);
  kit.interactables.add(it);
  tagInteract(g, it);
  return DeskView(
    def: def,
    group: g,
    laptopAnchor: laptopAnchor,
    seatAnchor: seatAnchor,
    stage: stage,
    chair: chair,
    vacancy: vacancy,
    vacancyY: 1.45,
  );
}
