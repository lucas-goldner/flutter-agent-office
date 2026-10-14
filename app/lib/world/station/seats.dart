// Where everyone sits and stands on the station: the long benches with a place at each for a worker,
// the board agents' consoles, the briefing table the meetings are held at, the bridge with the
// captain's chair on it, and the boards on the walls. Everything is where the plan has it (see
// planMap), as in the castle. A port of world/station/seats.ts and boards.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart' show DeskDef, Kiosk, StationKind, deskSeat, stationAgent;
import 'package:office_shared/maps/maps.dart' show Council, ThroneSize, benchOut, boardKeys;
import 'package:office_shared/maps/props.dart' show boxFootprint;
import 'package:office_shared/nav.dart' show deskPoint;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../geo.dart' as g3;
import '../office/geo.dart' show cyl, planeXY, yaw;
import '../office/office.dart' show DeskView, Face;
import '../office/parts.dart' show vacancyMarker;
import '../text.dart';
import '../toon.dart';
import 'kit.dart';

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

Geometry _ringFlat(double r, double tube, int radial, int tubular) =>
    g3.torusData(r, tube, radial, tubular).rotateX(math.pi / 2).build();

/// The long benches the workers work at, as the plan has them: a white top with a line of light down
/// it, a padded seat down each side.
void buildBenches(Kit kit) {
  final m = kit.mats;
  for (final t in kit.plan.tables) {
    final g = placed(t.x, 0, t.z, t.rotY, t.name);
    g.add(_m(roundedBox(t.width, 0.08, t.length, 0.08), m.white, 0, tableTop - 0.04, 0));
    g.add(_m(g3.box(t.width - 0.12, 0.05, t.length - 0.12), m.metalDark, 0, tableTop - 0.105, 0, false));
    g.add(_m(g3.box(0.1, 0.03, t.length - 0.6), m.accent, 0, tableTop + 0.012, 0, false));
    final legs = math.max(2, (t.length / 3.4).round() + 1);
    for (var i = 0; i < legs; i++) {
      final lz = -t.length / 2 + 0.5 + i * (t.length - 1) / (legs - 1);
      g.add(_m(g3.box(t.width - 0.5, tableTop - 0.13, 0.22), m.metalDark, 0, (tableTop - 0.13) / 2, lz));
      g.add(_m(g3.box(t.width - 0.2, 0.05, 0.5), m.metal, 0, 0.025, lz, false));
    }
    for (final s in t.sides) {
      final bx = s * (t.width / 2 + benchOut);
      g.add(_m(roundedBox(0.44, 0.09, t.length - 0.2, 0.05), m.pad, bx, benchTop - 0.045, 0));
      g.add(_m(g3.box(0.26, benchTop - 0.09, t.length - 0.8), m.metalDark, bx, (benchTop - 0.09) / 2, 0));
      collide(kit, t.x + math.cos(t.rotY) * bx, t.z - math.sin(t.rotY) * bx, 0.44, t.length - 0.2, t.rotY, benchTop);
    }
    kit.still.add(g);
    collide(kit, t.x, t.z, t.width, t.length, t.rotY, tableTop);
  }
}

/// A place at a bench: its laptop, the worker on the seat, a mug beside it, and the '+' while it's free.
({DeskView view, Interactable it}) placeSetting(Kit kit, DeskDef def, bool overflow) {
  final g = placed(def.x, 0, def.z, def.rotY, def.id);
  final laptopAnchor = Node(name: 'laptop-anchor')
    ..position = vm.Vector3(0, tableTop, -0.02)
    ..scale = vm.Vector3.all(1.2);
  g.add(laptopAnchor);
  // On the bench, facing the table.
  final seatAnchor = Node(name: 'seat-anchor')
    ..position = vm.Vector3(0, benchTop - 0.08, 0.85)
    ..rotation = yaw(math.pi)
    ..scale = vm.Vector3.all(0.82);
  g.add(seatAnchor);
  // Up on the table beside the laptop.
  final stage = Node(name: 'stage')..position = vm.Vector3(0.66, tableTop - 0.07, 0.12);
  g.add(stage);
  g.add(_m(cyl(0.05, 0.045, 0.11, 12), kit.mats.white, -0.6, tableTop + 0.055, 0.1, false));
  g.add(_m(g3.box(0.2, 0.012, 0.28), kit.mats.black, -0.62, tableTop + 0.006, -0.2, false));
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

const Map<StationKind, String> _consoleSign = {
  StationKind.issues: '📡 Ask me',
  StationKind.pulls: '🔀 Ask me',
  StationKind.queue: '📋 Ask me',
};

/// A board agent's console: a slanted panel on a pedestal, lit in the agent's color; it stands behind
/// it, as at the office's kiosk.
DeskView agentConsole(Kit kit, DeskDef def) {
  final kind = def.station!;
  final g = placed(def.x, 0, def.z, def.rotY, def.id);
  final m = kit.mats;
  final color = stationAgent[kind]!.color;
  final glow = lit(color);
  g.add(_m(cyl(0.3, 0.36, 0.06, 20), m.metalDark, 0, 0.03, 0));
  g.add(_m(cyl(0.09, 0.12, 0.92, 12), m.metal, 0, 0.5, 0));
  final top = Node(name: 'top')
    ..position = vm.Vector3(0, 1.0, 0)
    ..rotation = g3.euler(0.35, 0)
    ..add(_m(roundedBox(Kiosk.width, 0.07, Kiosk.depth, 0.05), m.metalDark))
    ..add(_m(g3.box(Kiosk.width - 0.12, 0.012, Kiosk.depth - 0.14), m.black, 0, 0.042, 0, false))
    ..add(_m(g3.box(Kiosk.width - 0.3, 0.014, 0.05), glow, 0, 0.045, -0.1, false))
    ..add(_m(g3.box(Kiosk.width - 0.4, 0.014, 0.05), glow, -0.05, 0.045, 0.02, false));
  g.add(top);
  // The agent's color round the pedestal, and a sign facing whoever walks up (-z, the room).
  g.add(_m(_ringFlat(0.13, 0.03, 6, 20), glow, 0, 0.72, 0, false));
  g.add(
    textPlane(_consoleSign[kind]!, TextOpts(bg: '#0f1a26', color: '#e6f6ff', border: color, size: 56))
      ..position = vm.Vector3(0, 0.42, -0.14)
      ..rotation = yaw(math.pi)
      ..scale = vm.Vector3.all(0.5),
  );
  final laptopAnchor = Node(name: 'laptop-anchor')..visible = false;
  g.add(laptopAnchor);
  // On its feet behind the console, facing it and the room beyond.
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

/// A board or a sign: a face the office paints a picture onto (see the controller's boards).
Face _face(double w, double h) {
  final mat = UnlitMaterial();
  return Face(mesh(planeXY(w, h), mat, 0, 0, 0, false), mat, w, h);
}

/// The round briefing table, its chairs, and the display on a stand with the meeting's board and sign.
({Face? board, Face? sign}) buildBriefing(Kit kit) {
  final cp = kit.plan.council;
  if (cp == null) return (board: null, sign: null);
  final m = kit.mats;
  const ch = Council.height, cr = Council.radius;
  final t = Node(name: 'briefing')
    ..position = vm.Vector3(cp.x, 0, cp.z)
    ..add(_m(cyl(cr, cr, 0.08, 36), m.white, 0, ch - 0.04, 0))
    ..add(_m(_ringFlat(cr, 0.03, 6, 40), m.accent, 0, ch - 0.04, 0, false))
    ..add(_m(cyl(0.2, 0.34, ch - 0.08, 16), m.metalDark, 0, (ch - 0.08) / 2, 0))
    ..add(_m(cyl(0.6, 0.66, 0.06, 20), m.metal, 0, 0.03, 0))
    // A projector let into the middle of it.
    ..add(_m(cyl(0.3, 0.3, 0.012, 24), m.black, 0, ch + 0.006, 0, false))
    ..add(_m(_ringFlat(0.3, 0.018, 6, 28), m.glow, 0, ch + 0.012, 0, false));
  kit.group.add(t);
  // A square inside the round top, so its corners don't stick out past the edge.
  final r = cr * math.sqrt1_2;
  kit.colliders.add(Collider(minX: cp.x - r, maxX: cp.x + r, minZ: cp.z - r, maxZ: cp.z + r, top: ch));
  final meeting = Interactable(kind: InteractKind.meeting, x: cp.x, z: cp.z, radius: 2.5);
  tagInteract(t, meeting);
  kit.interactables.add(meeting);
  for (final def in kit.plan.meeting) {
    kit.desks[def.id] = _briefingChair(kit, def);
  }
  // A display on a stand behind the table, away from its head, with the meeting's board and how it's going.
  final stand = placed(
    cp.x - math.sin(cp.rotY) * Council.easel,
    0,
    cp.z - math.cos(cp.rotY) * Council.easel,
    cp.rotY,
    'briefing-display',
  );
  for (final sx in const [-1, 1]) {
    stand.add(_m(g3.box(0.1, 2.3, 0.1), m.metalDark, sx * 1.05, 1.15, -0.04));
    stand.add(_m(g3.box(0.14, 0.06, 0.7), m.metalDark, sx * 1.05, 0.03, -0.04, false));
  }
  stand.add(_m(g3.box(2.52, 1.62, 0.08), m.black, 0, 1.95, 0.02));
  final board = _face(2.3, 1.4);
  board.node.position = vm.Vector3(0, 1.95, 0.07);
  stand.add(board.node);
  final sign = _face(1.2, 0.34);
  sign.node.position = vm.Vector3(0, 0.92, 0.07);
  stand.add(_m(g3.box(1.3, 0.42, 0.06), m.black, 0, 0.92, 0.02));
  stand.add(sign.node);
  stand.add(
    textPlane('🤝 Briefing room', const TextOpts(bg: '#0f1a26', color: '#cfeeff', border: '#3a5a78', size: 56))
      ..position = vm.Vector3(0, 2.98, 0.06)
      ..scale = vm.Vector3.all(0.62),
  );
  tagInteract(stand, meeting);
  kit.group.add(stand);
  final (minX, maxX, minZ, maxZ) = boxFootprint(stand.position.x, stand.position.z, 2.6, 0.5, cp.rotY);
  kit.colliders.add(Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, top: 99));
  return (board: board, sign: sign);
}

/// A chair at the briefing table: a padded seat and back on a pedestal, its laptop on the table in front of it.
DeskView _briefingChair(Kit kit, DeskDef def) {
  final g = placed(def.x, 0, def.z, def.rotY, def.id);
  final m = kit.mats;
  final chair = Node(name: 'chair')
    ..position = vm.Vector3(0, 0, 0.85)
    ..add(_m(cyl(0.26, 0.3, 0.05, 16), m.metalDark, 0, 0.025, 0))
    ..add(_m(cyl(0.05, 0.05, 0.4, 8), m.metal, 0, 0.24, 0))
    ..add(_m(roundedBox(0.54, 0.1, 0.52, 0.08), m.pad, 0, 0.47, 0))
    ..add(_m(roundedBox(0.5, 0.78, 0.09, 0.04), m.pad, 0, 0.95, 0.24))
    ..add(_m(g3.box(0.3, 0.05, 0.02), m.accent, 0, 1.22, 0.29, false));
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
  // A merge's dance party: up on its chair rather than the table, which the five laptops fill.
  final stage = Node(name: 'stage')..position = vm.Vector3(0, 0.52, 0.85);
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

/// The bridge: the raised deck at the forward end with its steps down, lit along their edges, the
/// captain's chair on it, and a helm console either side of the chair. Returns somewhere to sit.
Interactable? buildBridge(Kit kit) {
  final t = kit.plan.throne;
  final dais = kit.plan.dais;
  if (t == null || dais == null) return null;
  final m = kit.mats;
  final g = placed(t.x, 0, t.z, t.rotY, 'bridge');
  // It runs 2.4 m in front of the chair (the rest behind), with its steps down from there.
  const front = 2.4, stepD = 0.7;
  final top = dais.height;
  (double, double) at(double lx, double lz) =>
      (t.x + math.cos(t.rotY) * lx + math.sin(t.rotY) * lz, t.z - math.sin(t.rotY) * lx + math.cos(t.rotY) * lz);
  if (top > 0) {
    g.add(_m(g3.box(dais.width, top, dais.depth), m.metal, 0, top / 2, front - dais.depth / 2));
    g.add(
      _m(g3.box(dais.width - 0.3, 0.012, dais.depth - 0.3), m.metalDark, 0, top + 0.006, front - dais.depth / 2, false),
    );
    g.add(_m(g3.box(dais.width, 0.05, 0.05), m.accent, 0, top - 0.02, front + 0.005, false));
    final (cx, cz) = at(0, front - dais.depth / 2);
    collide(kit, cx, cz, dais.width, dais.depth, t.rotY, top);
    for (var k = 1; k <= dais.steps; k++) {
      final y = top * (dais.steps + 1 - k) / (dais.steps + 1);
      final lz = front + (k - 0.5) * stepD;
      g.add(_m(g3.box(dais.width - k * 0.4, y, stepD), m.metal, 0, y / 2, lz));
      g.add(_m(g3.box(dais.width - k * 0.4, 0.04, 0.04), m.accent, 0, y - 0.015, lz + stepD / 2 + 0.005, false));
      final (sx, sz) = at(0, lz);
      collide(kit, sx, sz, dais.width - k * 0.4, stepD, t.rotY, y);
    }
  }
  // The captain's chair: a wide padded seat on a pedestal, a high back with a headrest, a little panel on each arm.
  final chair = Node(name: 'captains-chair')
    ..position = vm.Vector3(0, top, 0)
    ..add(_m(cyl(0.62, 0.78, 0.16, 24), m.metalDark, 0, 0.08, -0.05))
    ..add(_m(cyl(0.2, 0.24, 0.38, 14), m.metal, 0, 0.35, -0.05))
    ..add(_m(roundedBox(1.1, 0.16, 1.0, 0.12), m.pad, 0, 0.66, 0.02))
    ..add(_m(roundedBox(1.0, 1.35, 0.2, 0.08), m.pad, 0, 1.35, -0.46))
    ..add(_m(roundedBox(0.62, 0.34, 0.24, 0.08), m.white, 0, 2.02, -0.45, false))
    ..add(_m(g3.box(1.14, 1.5, 0.12), m.metalDark, 0, 1.3, -0.6))
    ..add(_m(g3.box(0.7, 0.05, 0.03), m.accent, 0, 1.75, -0.35, false));
  for (final sx in const [-1, 1]) {
    chair
      ..add(_m(roundedBox(0.24, 0.3, 0.95, 0.08), m.metalDark, sx * 0.7, 0.86, 0))
      ..add(_m(g3.box(0.2, 0.012, 0.34), m.black, sx * 0.7, 1.017, 0.24, false))
      ..add(_m(g3.box(0.12, 0.014, 0.05), m.glow, sx * 0.7, 1.02, 0.3, false))
      ..add(_m(g3.box(0.12, 0.014, 0.05), m.accent, sx * 0.7, 1.02, 0.2, false));
  }
  g.add(chair);
  // The helm: a console either side of the chair, by the windows.
  for (final sx in const [-1, 1]) {
    final lx = sx * math.min(dais.width / 2 - 1.4, 5.6).toDouble();
    final lz = front - dais.depth + 3.2;
    final helm = placed(lx, top, lz, sx * -0.5, 'helm')
      ..add(_m(g3.box(1.9, 0.86, 0.5), m.metalDark, 0, 0.43, 0))
      ..add(_m(g3.box(1.9, 0.07, 0.72), m.black, 0, 0.94, 0.06, false)..rotation = g3.euler(0.35, 0));
    for (final (px, c) in [(-0.55, m.glow), (0.0, m.accent), (0.55, m.glow)]) {
      helm.add(_m(g3.box(0.4, 0.02, 0.4), c, px, 0.985, 0.08, false)..rotation = g3.euler(0.35, 0));
    }
    g.add(helm);
    final (hx, hz) = at(lx, lz);
    collide(kit, hx, hz, 1.9, 0.9, t.rotY + sx * -0.5, 99);
  }
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
  tagInteract(chair, seat);
  kit.interactables.add(seat);
  return seat;
}

/// The four boards: big displays on the walls, a line of light round each and its name over it. Their
/// faces by [BoardKey.wire], for the office to paint (see the controller's boards).
Map<String, Face> buildBoards(Kit kit) {
  final m = kit.mats;
  final faces = <String, Face>{};
  for (final k in boardKeys) {
    final bd = kit.plan.boards[k]!;
    final nx = math.sin(bd.rotY), nz = math.cos(bd.rotY);
    final g = placed(bd.x + nx * 0.1, bd.y, bd.z + nz * 0.1, bd.rotY, 'board-${k.wire}')
      ..add(_m(g3.box(bd.width + 0.34, bd.height + 0.34, 0.12), m.black));
    for (final sy in const [-1, 1]) {
      g.add(_m(g3.box(bd.width + 0.34, 0.04, 0.02), m.accent, 0, sy * (bd.height / 2 + 0.15), 0.065, false));
    }
    for (final sx in const [-1, 1]) {
      g.add(_m(g3.box(0.04, bd.height + 0.34, 0.02), m.accent, sx * (bd.width / 2 + 0.15), 0, 0.065, false));
    }
    final face = _face(bd.width, bd.height);
    face.node.position = vm.Vector3(0, 0, 0.07);
    g.add(face.node);
    faces[k.wire] = face;
    g.add(
      textPlane(bd.label, const TextOpts(bg: '#0f1a26', color: '#e6f6ff', size: 64, border: '#3a5a78'))
        ..position = vm.Vector3(0, bd.height / 2 + 0.55, 0.06)
        ..scale = vm.Vector3.all(1.1),
    );
    final it = Interactable(
      kind: InteractKind.values.byName(k.wire),
      x: bd.x + nx * 1.6,
      z: bd.z + nz * 1.6,
      radius: 2.4,
    );
    kit.interactables.add(it);
    tagInteract(g, it);
    kit.group.add(g);
  }
  return faces;
}
