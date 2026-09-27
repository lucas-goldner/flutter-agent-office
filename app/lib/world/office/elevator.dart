// The elevator: a steel shaft against the north wall, doors facing into the room. Every floor has
// it in the same place; riding it swaps the floor around you while the doors are shut.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../shared/layout.dart' as lay;
import '../../shared/layout.dart' show ElevatorCar, Floor, elevatorFront, wallHeight;
import '../collider.dart';
import '../text.dart';
import '../toon.dart';
import 'geo.dart';
import 'office_colliders.dart';
import 'parts.dart';

const _steel = '#b8c1cc';
const _steelDark = '#8d99ae';
const _brass = '#e9b949';

class Elevator {
  Elevator._(this.group, this.colliders, this.interactable, this._doors, this._doorCollider, this._pillar, this._half);

  final Node group;

  /// What stops you walking out through shut doors. Part of the office's colliders.
  final List<Collider> colliders;

  /// Step in, or up to the call button, and press E.
  final Interactable interactable;

  final List<(Node, int)> _doors;
  final Collider _doorCollider;
  final double _pillar;
  final double _half;
  Node? _sign;
  bool _open = false;
  double _openness = 0; // 0 shut, 1 open

  bool get open => _open;

  /// Whether the doors have finished moving.
  bool get settled => _openness == (_open ? 1 : 0);

  /// Opens or shuts the doors; they slide there over a moment.
  void setOpen(bool v) {
    _open = v;
    // Shut means shut at once for walking, so nobody slips out while they close.
    if (!v) _doorCollider.top = 99;
  }

  /// The sign over the doors, and the display inside: which floor this is.
  void setSign(String text) {
    final old = _sign;
    if (old != null) group.remove(old);
    const opts = TextOpts(bg: '#2b2d42', color: '#fffaf3', size: 64, border: '#fffaf3');
    final painted = paintText(text, opts);
    final sw = painted.w * kTextScale;
    painted.picture.dispose();
    final sign = textPlane(text, opts);
    // As big as fits over the doors.
    final s = math.min(1.6, (lay.Elevator.width + 0.6) / sw);
    group.add(place(sign, x: lay.Elevator.x, y: lay.Elevator.doorHeight + 0.75, z: elevatorFront + 0.03, scale: s));
    _sign = sign;
  }

  void update(double dt) {
    final target = _open ? 1.0 : 0.0;
    if (_openness != target) {
      _openness = target > _openness ? math.min(1, _openness + dt / 0.7) : math.max(0, _openness - dt / 0.6);
      // Eased, like a real one: slow to start, slow to stop.
      final e = _openness * _openness * (3 - 2 * _openness);
      // As far as the pillars hide them; a sliver still shows at the edge of the doorway.
      for (final (d, side) in _doors) {
        final p = d.position;
        d.position = vm.Vector3(lay.Elevator.x + side * _half / 2 + side * e * (_pillar - 0.03), p.y, p.z);
      }
    }
    if (_open && _openness > 0.85) _doorCollider.top = -1;
  }
}

Elevator buildElevator() {
  const x = lay.Elevator.x, width = lay.Elevator.width, depth = lay.Elevator.depth, wall = lay.Elevator.wall;
  const doorWidth = lay.Elevator.doorWidth, doorHeight = lay.Elevator.doorHeight;
  final group = Node(name: 'elevator');
  const minX = x - width / 2;
  const maxX = x + width / 2;
  const back = Floor.minZ;
  const front = elevatorFront;
  const midZ = (back + front) / 2;
  final steel = tc(_steel);
  final steelDark = tc(_steelDark);
  final brass = tc(_brass);
  // The shaft, its trim and the car's insides never move: merged at the end.
  final stat = Node(name: 'shaft');

  // Side walls, the whole height of the room.
  for (final sx in [minX + wall / 2, maxX - wall / 2]) {
    stat.add(mesh(box(wall, wallHeight, depth), steel, sx, wallHeight / 2, midZ));
  }
  // The front: a pillar either side of the doorway, and a header over it up to the ceiling line.
  const pillar = (width - doorWidth) / 2;
  for (final (x0, x1) in [(minX, x - doorWidth / 2), (x + doorWidth / 2, maxX)]) {
    stat.add(mesh(box(pillar, wallHeight, wall), steel, (x0 + x1) / 2, wallHeight / 2, front - wall / 2));
  }
  const header = wallHeight - doorHeight;
  stat.add(mesh(box(doorWidth, header, wall), steel, x, doorHeight + header / 2, front - wall / 2));
  // A brass frame round the doorway, and a kick plate along the bottom of the shaft.
  const frameT = 0.08;
  stat.add(mesh(box(doorWidth + frameT * 2, frameT, 0.05), brass, x, doorHeight + frameT / 2, front + 0.02, false));
  for (final sx in [-1, 1]) {
    stat.add(mesh(box(frameT, doorHeight, 0.05), brass, x + sx * (doorWidth / 2 + frameT / 2), doorHeight / 2, front + 0.02, false));
  }
  stat.add(mesh(box(width + 0.02, 0.25, wall + 0.04), steelDark, x, 0.125, front - wall / 2, false));

  // Inside: a dark floor, a mirror on the back wall, handrails, a strip light over the doors.
  const inW = ElevatorCar.maxX - ElevatorCar.minX;
  const inD = ElevatorCar.maxZ - ElevatorCar.minZ;
  stat.add(mesh(box(inW, 0.02, inD), tc('#3d405b'), x, 0.012, (ElevatorCar.minZ + ElevatorCar.maxZ) / 2, false));
  for (var i = 1; i < 4; i++) {
    stat.add(mesh(box(inW, 0.024, 0.03), tc('#565a75'), x, 0.013, ElevatorCar.minZ + i * inD / 4, false));
  }
  stat.add(mesh(planeXY(inW - 0.3, 1.5), flat('#cfe8f5'), x, 1.55, back + 0.02, false));
  final glintMat = seeThrough('#ffffff', 0.5);
  for (final (gx, gw) in [(-0.4, 0.14), (-0.15, 0.06)]) {
    stat.add(place(mesh(planeXY(gw, 1.1), glintMat, 0, 0, 0, false), x: x + gx, y: 1.6, z: back + 0.03, rot: euler(0, 0, -0.45)));
  }
  void rail(double len, double px, double pz, bool alongX) {
    final r = mesh(cyl(0.025, 0.025, len, 8), brass, 0, 0, 0, false);
    stat.add(place(r, x: px, y: 0.95, z: pz, rot: alongX ? euler(0, 0, math.pi / 2) : euler(math.pi / 2)));
  }

  rail(inW - 0.2, x, back + 0.08, true);
  rail(inD - 0.5, ElevatorCar.minX + 0.06, midZ - 0.1, false);
  rail(inD - 0.5, ElevatorCar.maxX - 0.06, midZ - 0.1, false);
  stat.add(mesh(box(inW - 0.2, 0.06, 0.16), tc('#fff7d6', emissive: '#ffe08a'), x, doorHeight + 0.35, front - wall - 0.1, false));

  // The button panel inside, by the doors on the right as you face out (the west wall).
  final panelIn = Node(name: 'panel');
  panelIn.add(mesh(roundedBox(0.04, 0.7, 0.32, 0.02), steelDark, 0, 0, 0, false));
  for (var row = 0; row < 4; row++) {
    for (final col in [-1, 1]) {
      final lit = row == 0 && col == 1;
      final b = mesh(cyl(0.035, 0.035, 0.02, 12), tc('#fff7d6', emissive: lit ? '#ffb400' : '#6c7288'), 0, 0, 0, false);
      panelIn.add(place(b, x: -0.03, y: 0.22 - row * 0.15, z: col * 0.07, rot: euler(0, 0, math.pi / 2)));
    }
  }
  stat.add(place(panelIn, x: ElevatorCar.minX + 0.03, y: 1.25, z: front - wall - 0.35, rot: yaw(math.pi)));

  // The call button outside, on the right-hand pillar.
  final call = Node(name: 'call');
  call.add(mesh(roundedBox(0.2, 0.36, 0.04, 0.02), brass, 0, 0, 0, false));
  for (final up in [true, false]) {
    final a = mesh(cone(0.045, 0.06, 3), tc('#fff7d6', emissive: up ? '#7cf29a' : '#6c7288'), 0, 0, 0, false);
    call.add(place(a, y: up ? 0.07 : -0.07, z: 0.03, rot: up ? null : euler(0, 0, math.pi)));
  }
  stat.add(place(call, x: x + doorWidth / 2 + pillar / 2, y: 1.2, z: front + 0.02));

  // The doors: two steel panels that slide apart behind the pillars.
  const half = doorWidth / 2 + 0.02;
  const doorZ = front - wall - 0.03;
  final doorMat = tc('#d9dee4');
  final doors = <(Node, int)>[];
  for (final side in [-1, 1]) {
    final d = Node(name: 'door');
    d.add(mesh(box(half, doorHeight - 0.02, 0.05), doorMat, 0, 0, 0));
    // A seam line and a porthole of light, so they read as elevator doors from across the room.
    d.add(mesh(box(0.02, doorHeight - 0.1, 0.055), steelDark, -side * half / 2 + side * 0.01, 0, 0, false));
    d.add(mesh(box(half - 0.2, 0.05, 0.055), steelDark, 0, 0.35, 0, false));
    group.add(place(d, x: x + side * half / 2, y: doorHeight / 2, z: doorZ));
    doors.add((d, side));
  }

  group.add(mergeByMaterial(stat));
  final colliders = elevatorColliders();
  final interactable = Interactable(kind: InteractKind.elevator, x: x, z: front - 0.4, radius: 1.9);
  tagInteract(group, interactable);
  return Elevator._(group, colliders, interactable, doors, colliders.last, pillar, half);
}
