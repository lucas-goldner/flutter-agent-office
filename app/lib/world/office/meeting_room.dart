// The meeting room under the loft (office.ts buildMeetingRoom): glass walls from the loft's posts round
// to the outside walls, a sliding glass door facing the lounge, a long table with its chairs
// (meetingSeats), a board on the back wall for the meeting's output and a sign by the door for how
// it's going (world/meeting.dart paints them).

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'office.dart';
import 'parts.dart';
import 'shell.dart' show Door;

const double _t = 0.1;

/// What you bump into: the glass walls (not the door) and the table.
List<Collider> meetingColliders() {
  const r = MeetingRoom.minX, h = MeetingRoom.height;
  const top = (x: MeetingTable.x, z: MeetingTable.z, w: MeetingTable.width, d: MeetingTable.depth);
  return [
    Collider(
      minX: r,
      maxX: MeetingRoom.door.x0,
      minZ: MeetingRoom.minZ - _t / 2,
      maxZ: MeetingRoom.minZ + _t / 2,
      top: h,
    ),
    Collider(
      minX: MeetingRoom.door.x1,
      maxX: MeetingRoom.maxX,
      minZ: MeetingRoom.minZ - _t / 2,
      maxZ: MeetingRoom.minZ + _t / 2,
      top: h,
    ),
    Collider(minX: r - _t / 2, maxX: r + _t / 2, minZ: MeetingRoom.minZ, maxZ: MeetingRoom.maxZ, top: h),
    Collider(
      minX: top.x - top.w / 2,
      maxX: top.x + top.w / 2,
      minZ: top.z - top.d / 2,
      maxZ: top.z + top.d / 2,
      top: MeetingTable.height,
    ),
  ];
}

/// A chair at the meeting table, with its laptop on the table in front of it.
DeskView _buildSeat(DeskDef def, int index) {
  final group = Node(name: def.id);
  group.position = vm.Vector3(def.x, 0, def.z);
  group.rotation = yaw(def.rotY);
  final laptopAnchor = place(Node(name: 'laptop-anchor'), y: MeetingTable.height, scale: 1.15);
  group.add(laptopAnchor);
  final seatAnchor = place(Node(name: 'seat-anchor'), y: 0.4, z: 0.85, rot: yaw(math.pi), scale: 0.82);
  group.add(seatAnchor);
  final ch = place(chair(const ['#2b2d42', '#ef476f', '#118ab2', '#06d6a0', '#ffd166'][index % 5]), z: 0.85);
  group.add(ch);
  // Nobody is hired here from the floor, so there's no '+' over a free chair: a meeting fills them.
  final vacancy = Node(name: 'vacancy');
  group.add(vacancy);
  return DeskView(
    def: def,
    group: group,
    laptopAnchor: laptopAnchor,
    seatAnchor: seatAnchor,
    chair: ch,
    vacancy: vacancy,
    vacancyY: 0,
  );
}

/// Builds the meeting room into [office]; returns its board and the sign by its door.
({Face board, Face sign}) buildMeetingRoom(Office office) {
  final group = office.group;
  const h = MeetingRoom.height;
  final frameMat = tc('#ffffff');
  final walls = Node(name: 'meeting-walls');
  void bar(double w, double bh, double d, double x, double y, double z) =>
      walls.add(mesh(box(w, bh, d), frameMat, x, y, z, false));

  /// A run of glass along x (the north wall) or z (the west wall), from a to b, in panes about [pane] wide.
  void run(bool alongX, double a, double b, double at, [double pane = 2.2]) {
    final len = b - a;
    final n = math.max(1, (len / pane).round());
    for (var i = 0; i < n; i++) {
      final u = a + (i + 0.5) * (len / n);
      final g = glassPane(len / n, h);
      walls.add(alongX ? place(g, x: u, y: h / 2, z: at) : place(g, x: at, y: h / 2, z: u, rot: yaw(math.pi / 2)));
    }
    for (var i = 0; i <= n; i++) {
      final u = a + i * (len / n);
      if (alongX) {
        bar(0.08, h, _t + 0.04, u, h / 2, at);
      } else {
        bar(_t + 0.04, h, 0.08, at, h / 2, u);
      }
    }
    for (final y in [0.05, h - 0.05]) {
      if (alongX) {
        bar(len, 0.1, _t + 0.06, (a + b) / 2, y, at);
      } else {
        bar(_t + 0.06, 0.1, len, at, y, (a + b) / 2);
      }
    }
  }

  const door = MeetingRoom.door;
  run(true, MeetingRoom.minX, door.x0, MeetingRoom.minZ);
  run(true, door.x1, MeetingRoom.maxX, MeetingRoom.minZ);
  run(false, MeetingRoom.minZ, MeetingRoom.maxZ, MeetingRoom.minX);
  // Over the door, up to the loft's floor.
  bar(door.x1 - door.x0, 0.1, _t + 0.06, (door.x0 + door.x1) / 2, 2.3, MeetingRoom.minZ);
  group.add(walls);

  // The door: two glass leaves that slide apart over the glass on either side when someone comes up.
  final dx = (door.x0 + door.x1) / 2;
  final half = (door.x1 - door.x0) / 2;
  final alu = tc('#aab4be');
  final leaves = <(Node, double)>[];
  for (final side in [-1, 1]) {
    final leaf = Node(name: 'meeting-door');
    const lh = 2.25;
    for (final y in [0.04, lh - 0.04]) {
      leaf.add(mesh(box(half, 0.07, 0.04), alu, 0, y, 0, false));
    }
    for (final x in [-half / 2 + 0.03, half / 2 - 0.03]) {
      leaf.add(mesh(box(0.06, lh, 0.04), alu, x, lh / 2, 0, false));
    }
    leaf.add(place(glassPane(half - 0.12, lh - 0.14), y: lh / 2));
    leaf.add(mesh(box(0.03, 0.4, 0.07), tc(Palette.ink), -side * (half / 2 - 0.1), 1.05, 0, false));
    final x0 = dx + side * half / 2;
    leaf.position = vm.Vector3(x0, 0, MeetingRoom.minZ - _t / 2 - 0.04);
    group.add(leaf);
    leaves.add((leaf, x0));
  }
  office.addDoor(
    Door(dx, 0, MeetingRoom.minZ, (k) {
      final e = k * k * (3 - 2 * k);
      for (final (leaf, x0) in leaves) {
        leaf.position = vm.Vector3(x0 + (x0 - dx).sign * e * (half - 0.06), 0, leaf.position.z);
      }
    }),
  );
  group.add(
    place(
      textPlane('🤝 Meeting room', const TextOpts(bg: '#2b2d42', color: '#fffaf3', size: 56, border: '#fffaf3')),
      x: dx,
      y: 2.52,
      z: MeetingRoom.minZ - 0.07,
      rot: yaw(math.pi),
      scale: 0.62,
    ),
  );

  // The table, on two pedestals, and its chairs.
  final table = Node(name: 'meeting-table');
  const top = (width: MeetingTable.width, depth: MeetingTable.depth, height: MeetingTable.height);
  table.add(mesh(roundedBox(top.width, 0.08, top.depth, 0.1), tc(Palette.wood), 0, top.height - 0.04, 0));
  for (final sx in [-1, 1]) {
    table.add(
      mesh(
        cyl(0.1, 0.12, top.height - 0.08, 10),
        tc(Palette.deskLeg),
        sx * (top.width / 2 - 0.7),
        (top.height - 0.08) / 2,
        0,
      ),
    );
    table.add(mesh(roundedBox(0.9, 0.05, 0.6, 0.05), tc(Palette.deskLeg), sx * (top.width / 2 - 0.7), 0.025, 0));
  }
  final tableNode = place(mergeByMaterial(table), x: MeetingTable.x, z: MeetingTable.z);
  group.add(tableNode);
  final talk = Interactable(kind: InteractKind.meeting, x: MeetingTable.x, z: MeetingTable.z, radius: 2.6);
  office.interactables.add(talk);
  tagInteract(tableNode, talk);
  for (var i = 0; i < meetingSeats.length; i++) {
    final def = meetingSeats[i];
    final view = _buildSeat(def, i);
    group.add(view.group);
    office.desks[def.id] = view;
    final at = deskSeat(def, 1.2);
    final it = Interactable(kind: InteractKind.desk, deskId: def.id, x: at.x, z: at.z, radius: 1);
    office.interactables.add(it);
    tagInteract(view.group, it);
  }

  // The board on the back wall: the meeting's output file as it's being written.
  const b = MeetingBoard.width, bh = MeetingBoard.height;
  final frame = Node(name: 'meeting-board');
  frame.add(place(mesh(roundedBox(b + 0.3, 0.12, bh + 0.3, 0.1), tc('#aab4be')), rot: euler(math.pi / 2)));
  final boardMat = flat('#fbfdff');
  final boardFace = mesh(planeXY(b, bh), boardMat, 0, 0, 0.07, false);
  frame.add(boardFace);
  group.add(place(frame, x: MeetingBoard.x, y: MeetingBoard.y, z: MeetingBoard.z, rot: yaw(math.pi)));
  final read = Interactable(kind: InteractKind.meeting, x: MeetingBoard.x, z: MeetingBoard.z - 1.4, radius: 2.4);
  office.interactables.add(read);
  tagInteract(frame, read);

  // The panel on the glass beside the door, like a room-booking screen.
  final sx = (MeetingRoom.minX + MeetingRoom.door.x0) / 2 + 0.01;
  final signMat = flat('#2b2d42');
  final sign = place(
    mesh(planeXY(0.6, 0.96), signMat, 0, 0, 0, false),
    x: sx,
    y: 1.45,
    z: MeetingRoom.minZ - _t / 2 - 0.03,
    rot: yaw(math.pi),
  );
  group.add(sign);
  final plate = mesh(
    roundedBox(0.66, 1.03, 0.03, 0.03),
    tc(Palette.ink),
    sx,
    1.45,
    MeetingRoom.minZ - _t / 2 - 0.012,
    false,
  );
  group.add(plate);
  final doorIt = Interactable(kind: InteractKind.meeting, x: sx, z: MeetingRoom.minZ - 1.2, radius: 1.8);
  office.interactables.add(doorIt);
  tagInteract(sign, doorIt);
  tagInteract(plate, doorIt);

  // Flat lights set in the loft's floor over the table: a hanging lamp would be in front of the board.
  for (final ox in [-0.95, 0.95]) {
    group.add(
      mesh(
        cyl(0.34, 0.34, 0.04, 20),
        tc('#fff7d6', emissive: '#ffe08a'),
        MeetingTable.x + ox,
        h - 0.02,
        MeetingTable.z,
        false,
      ),
    );
    office.night.halos.add(
      Halo(at: vm.Vector3(MeetingTable.x + ox, h - 0.08, MeetingTable.z), size: 0.9, color: '#ffe08a'),
    );
  }
  return (board: Face(boardFace, boardMat, b, bh), sign: Face(sign, signMat, 0.6, 0.96));
}
