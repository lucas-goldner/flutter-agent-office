// The rest of the building, from outside (a port of world/tower.ts): a floor per project, stacked
// into a tower. Only the floor you're on is really there; the others are its outside (walls,
// windows, a balcony off each, a cornice round the top and the rooftop bar over it, roughly),
// rebuilt whenever floors come and go or you change floors. Up on the roof it's every floor, under
// your feet.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' hide Gong, Jukebox, Whiteboard;

import '../collider.dart';
import '../toon.dart';
import 'geo.dart';
import 'outside.dart';
import 'parts.dart';

/// The outside's planes stand this far off the walls, so they never fight the floor you're on for a pixel.
const double _off = 0.01;

/// The building, walls included.
abstract final class _B {
  static const double minX = Floor.minX - wallT;
  static const double maxX = Floor.maxX + wallT;
  static const double minZ = Floor.minZ - wallT;
  static const double maxZ = Floor.maxZ + wallT;
}

/// One side of the building: where along it things are (u, from corner to corner), and its plane.
class _Face {
  const _Face(this.u0, this.u1, this.at, this.rotY);
  final double u0, u1;
  final vm.Vector3 Function(double u, double y) at;
  final double rotY;
}

final Map<Side, _Face> _faces = {
  Side.north: _Face(_B.minX - _off, _B.maxX + _off, (u, y) => vm.Vector3(u, y, _B.minZ - _off), math.pi),
  Side.south: _Face(_B.minX - _off, _B.maxX + _off, (u, y) => vm.Vector3(u, y, _B.maxZ + _off), 0),
  Side.west: _Face(_B.minZ - _off, _B.maxZ + _off, (u, y) => vm.Vector3(_B.minX - _off, y, u), -math.pi / 2),
  Side.east: _Face(_B.minZ - _off, _B.maxZ + _off, (u, y) => vm.Vector3(_B.maxX + _off, y, u), math.pi / 2),
};

/// A wall-built group (along x, outdoors toward +z) turned onto [side], [u] along it.
Node _onFace(Node g, Side side, double u) {
  final f = _faces[side]!;
  final p = f.at(u, 0);
  return place(g, x: p.x, y: p.y, z: p.z, rot: yaw(f.rotY));
}

/// What the tower is out of the floors [floorIndex] of [count] (see [Tower.set]): which floors
/// stand as outsides, how far up (or down) each is, and whether there's a cornice and the rooftop
/// bar on top, and at what height.
({List<({int k, double y0})> floors, double? top}) towerPlan(int floorIndex, int count) => (
  floors: [
    for (var k = 0; k < count; k++)
      if (k != floorIndex) (k: k, y0: (k - floorIndex) * storey),
  ],
  top: floorIndex < count ? (count - 1 - floorIndex) * storey + wallHeight : null,
);

/// The walls down to the garage below you, which you can't walk into from the steps outside the
/// bottom floor's door, and the bottom floor's slab (the garage's ceiling), on floor [floorIndex] of [count].
List<Collider> towerColliders(int floorIndex, int count) {
  if (floorIndex <= 0 || floorIndex >= count) return const [];
  final bottom = -floorIndex * storey - slab;
  const t = wallT;
  return [
    Collider(minX: _B.minX, maxX: _B.maxX, minZ: _B.minZ, maxZ: _B.minZ + t, bottom: bottom, top: -slab),
    Collider(minX: _B.minX, maxX: _B.maxX, minZ: _B.maxZ - t, maxZ: _B.maxZ, bottom: bottom, top: -slab),
    Collider(minX: _B.minX, maxX: _B.minX + t, minZ: _B.minZ, maxZ: _B.maxZ, bottom: bottom, top: -slab),
    Collider(minX: _B.maxX - t, maxX: _B.maxX, minZ: _B.minZ, maxZ: _B.maxZ, bottom: bottom, top: -slab),
    Collider(minX: _B.minX, maxX: _B.maxX, minZ: _B.minZ, maxZ: _B.maxZ, bottom: bottom, top: bottom + slab),
  ];
}

/// The rest of the building. Its colliders go in the list it was built with.
class Tower {
  Tower._(this._colliders, NightParts night) {
    _paint = toonUnique(hex('#e07a5f'));
    _band = toonUnique(hex('#e8a87c'));
    _frame = tc('#ffffff');
    _alu = tc('#aab4be');
    _ink = tc('#3d405b');
    _wood = tc('#c98b5a');
    _deck = tc('#e8a87c');
    _cornice = tc('#fffaf3');
    _behind = toonUnique(hex('#2b2d42'));
    _dark = tc('#a9d8f5');
    // Glass you can't see into; at night some of it glows, as though someone upstairs is still at it.
    _lit = [
      for (final glow in ['#ffd27a', '#ffe6b0', '#9ec9ff'])
        () {
          final m = toonUnique(hex('#a9d8f5'));
          night.bulbs.add(NightBulb(m, hex(glow), 0));
          return m;
        }(),
    ];
    _glint = seeThrough('#ffffff', 0.35);
    _railGlass = seeThrough('#d6f1ff', 0.14);
    _curb = tc('#d8d3ca');
    _steel = tc('#b8c1cc');
    _steelDark = tc('#8d99ae');
    _beacon = bulb(night, '#ff5d5d', 0.6);
    _stage = tc('#2b2d42');
    _black = tc('#1d1d1d');
    _led = bulb(night, '#7b2ff7', 0.35);
    _truss = tc('#c9d1d9');
    _barWood = tc('#6b3f2a');
    _counter = tc('#f4f1ea');
    _shelf = tc('#4a2c1d');
    _pergola = tc('#8a5a3b');
    _parasol = tc('#ef476f');
  }

  final Node group = Node(name: 'tower');
  final List<Collider> _colliders;
  late final Material _paint, _band, _frame, _alu, _ink, _wood, _deck, _cornice, _behind, _dark, _glint, _railGlass;
  late final List<Material> _lit;
  late final Material _curb, _steel, _steelDark, _beacon, _stage, _black, _led, _truss, _barWood, _counter, _shelf;
  late final Material _pergola, _parasol;
  Node? _built;
  final List<Collider> _mine = [];
  int _seed = 1;

  /// The same windows light up each time a floor's outside is rebuilt.
  double _random() {
    _seed = (_seed * 16807) % 2147483647;
    return _seed / 2147483647;
  }

  /// One floor's outside on [side], [y0] up from the floor you're on: the band of its slab, then its
  /// wall round its windows and doors.
  void _facade(Node parts, Side side, double y0, List<Opening> holes) {
    final f = _faces[side]!;
    void piece(double u0, double u1, double y1, double y2, Material mat) {
      if (u1 - u0 < 0.001 || y2 - y1 < 0.001) return;
      final p = f.at((u0 + u1) / 2, (y1 + y2) / 2);
      parts.add(place(mesh(planeXY(u1 - u0, y2 - y1), mat, 0, 0, 0, false), x: p.x, y: p.y, z: p.z, rot: yaw(f.rotY)));
    }

    piece(f.u0, f.u1, y0 - slab, y0, _band);
    var u = f.u0;
    for (final o in [...holes]..sort((a, b) => a.u.compareTo(b.u))) {
      final h0 = o.u - o.width / 2, h1 = o.u + o.width / 2;
      piece(u, h0, y0, y0 + wallHeight, _paint);
      piece(h0, h1, y0, y0 + o.y0, _paint);
      piece(h0, h1, y0 + o.y1, y0 + wallHeight, _paint);
      u = h1;
    }
    piece(u, f.u1, y0, y0 + wallHeight, _paint);
  }

  /// Glass in a hole: set back a little, with a frame round it, a bar down the middle and a sill.
  void _glazing(Node parts, Opening o, double y0, bool door) {
    final g = Node(name: 'glazing');
    final w = o.width, h = o.y1 - o.y0;
    final f = door ? 0.08 : 0.09;
    final edge = door ? _alu : _frame;
    final glass = _random() < 0.4 ? _lit[(_random() * _lit.length).floor()] : _dark;
    final mid = y0 + (o.y0 + o.y1) / 2;
    g.add(mesh(planeXY(w - 2 * f, h - 2 * f), glass, 0, mid, -0.06, false));
    g.add(
      place(
        mesh(planeXY(0.16, h * 0.55), _glint, 0, 0, 0, false),
        x: -w * 0.18,
        y: mid + h * 0.05,
        z: -0.05,
        rot: euler(0, 0, -0.5),
      ),
    );
    g.add(mesh(box(w, f, 0.14), edge, 0, y0 + o.y1 - f / 2, -0.05, false));
    g.add(mesh(box(w, f, 0.14), edge, 0, y0 + o.y0 + f / 2, -0.05, false));
    for (final sx in [-1, 1]) {
      g.add(mesh(box(f, h, 0.14), edge, sx * (w / 2 - f / 2), mid, -0.05, false));
    }
    g.add(mesh(box(f * (door ? 1 : 0.8), h - 2 * f, 0.08), edge, 0, mid, -0.05, false));
    if (!door) g.add(mesh(box(w + 0.2, 0.06, 0.16), _frame, 0, y0 + o.y0 - 0.03, 0.06, false));
    parts.add(_onFace(g, o.wall, o.u));
  }

  /// The balcony off a floor [y0] up: its deck, and a railing with glass in it round the three open sides.
  void _balcony(Node parts, double y0) {
    const minX = Balcony.minX, maxX = Balcony.maxX, minZ = Balcony.minZ, maxZ = Balcony.maxZ;
    const w = maxX - minX, d = maxZ - minZ;
    parts.add(mesh(box(w, slab - 0.01, d), _deck, (minX + maxX) / 2, y0 - slab / 2 - 0.005, (minZ + maxZ) / 2, false));
    const railH = 1.05, inset = 0.06;
    const sides = [
      (minX + inset, maxZ - inset, maxX - inset, maxZ - inset),
      (minX + inset, minZ, minX + inset, maxZ - inset),
      (maxX - inset, minZ, maxX - inset, maxZ - inset),
    ];
    for (final (x0, z0, x1, z1) in sides) {
      final len = math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0));
      final alongX = z0 == z1;
      final n = (len / 1.6).ceil();
      for (var i = 0; i <= n; i++) {
        parts.add(
          mesh(box(0.06, railH, 0.06), _ink, x0 + (x1 - x0) * i / n, y0 + railH / 2, z0 + (z1 - z0) * i / n, false),
        );
      }
      parts.add(
        mesh(
          alongX ? box(len + 0.1, 0.07, 0.12) : box(0.12, 0.07, len + 0.1),
          _wood,
          (x0 + x1) / 2,
          y0 + railH + 0.02,
          (z0 + z1) / 2,
          false,
        ),
      );
      parts.add(
        place(
          mesh(planeXY(len - 0.1, railH - 0.2, both: true), _railGlass, 0, 0, 0, false),
          x: (x0 + x1) / 2,
          y: y0 + (railH - 0.2) / 2 + 0.08,
          z: (z0 + z1) / 2,
          rot: yaw(alongX ? 0 : math.pi / 2),
        ),
      );
    }
  }

  /// A cornice round the top of the building, [top] up: along each wall, and out past it at both
  /// corners so the four meet.
  void _crown(Node parts, double top) {
    const h = 0.45, out = 0.22;
    for (final side in Side.values) {
      final f = _faces[side]!;
      final g = Node(name: 'cornice');
      final len = f.u1 - f.u0 + 2 * out;
      g.add(mesh(box(len, h, wallT + out), _cornice, 0, top + h / 2, out / 2 - wallT / 2 - _off, false));
      g.add(mesh(box(len, 0.08, 0.06), _band, 0, top + 0.1, out - _off + 0.03, false));
      parts.add(_onFace(g, side, (f.u0 + f.u1) / 2));
    }
  }

  /// The rooftop bar on the roof, [y] up, roughly, as it looks from down below (rooftop.dart has the
  /// real one): a curb round the edge with glass and a rail, the elevator's housing, the DJ's stage
  /// with the LED wall and the rig, the bar under its pergola, and parasols along the south edge.
  void _roofTop(Node parts, double y) {
    void bx(double w, double h, double d, Material mat, double x, double y0, double z) =>
        parts.add(mesh(box(w, h, d), mat, x, y0 + h / 2, z, false));
    const edges = [
      (_B.minX, _B.maxX, _B.minZ, Floor.minZ),
      (_B.minX, _B.maxX, Floor.maxZ, _B.maxZ),
      (_B.minX, Floor.minX, _B.minZ, _B.maxZ),
      (Floor.maxX, _B.maxX, _B.minZ, _B.maxZ),
    ];
    for (final (x0, x1, z0, z1) in edges) {
      final ex = (x0 + x1) / 2, ez = (z0 + z1) / 2;
      final alongX = x1 - x0 > z1 - z0;
      final len = alongX ? x1 - x0 : z1 - z0;
      bx(x1 - x0, 0.45, z1 - z0, _curb, ex, y, ez);
      parts.add(
        place(
          mesh(planeXY(len, 0.72, both: true), _railGlass, 0, 0, 0, false),
          x: ex,
          y: y + 0.81,
          z: ez,
          rot: yaw(alongX ? 0 : math.pi / 2),
        ),
      );
      bx(alongX ? len : 0.07, 0.07, alongX ? 0.07 : len, _steel, ex, y + 1.155, ez);
      for (var a = 0.0; a <= len + 0.01; a += 2.4) {
        bx(0.06, 0.75, 0.06, _steel, alongX ? x0 + a : ex, y + 0.425, alongX ? ez : z0 + a);
      }
    }

    // The elevator's housing, as tall as a floor, with a light on top.
    const hz = (_B.minZ + elevatorFront) / 2;
    bx(Elevator.width, wallHeight, elevatorFront - _B.minZ, _steel, Elevator.x, y, hz);
    bx(Elevator.width + 0.3, 0.3, elevatorFront - _B.minZ + 0.2, _steelDark, Elevator.x, y + wallHeight, hz + 0.05);
    parts.add(mesh(sphere(0.12, 10, 8), _beacon, Elevator.x, y + wallHeight + 0.4, hz, false));

    // The stage, the LED wall behind the DJ, and the rig: a truss tower either side and a beam across.
    const sw = Stage.maxX - Stage.minX, scx = (Stage.minX + Stage.maxX) / 2;
    bx(sw, Stage.height, Stage.maxZ - Stage.minZ, _stage, scx, y, (Stage.minZ + Stage.maxZ) / 2);
    bx(8.3, 4.3, 0.25, _black, scx, y + Stage.height + 0.2, Stage.minZ + 0.06);
    parts.add(mesh(planeXY(8, 4), _led, scx, y + Stage.height + 2.35, Stage.minZ + 0.2, false));
    const rigZ = Stage.maxZ - 0.15, rigTop = 5.6;
    for (final x in [Stage.minX + 0.2, Stage.maxX - 0.2]) {
      bx(0.34, rigTop - Stage.height, 0.34, _truss, x, y + Stage.height, rigZ);
    }
    bx(sw - 0.4, 0.34, 0.34, _truss, scx, y + rigTop - 0.34, rigZ);

    // The bar along the east side, the shelves of bottles behind it, and the pergola over both.
    const blen = RoofBar.maxZ - RoofBar.minZ, bz = (RoofBar.minZ + RoofBar.maxZ) / 2;
    const front = RoofBar.x - RoofBar.depth / 2;
    bx(RoofBar.depth, RoofBar.height - 0.06, blen, _barWood, RoofBar.x, y, bz);
    bx(RoofBar.depth + 0.2, 0.06, blen + 0.2, _counter, RoofBar.x - 0.05, y + RoofBar.height - 0.06, bz);
    bx(0.6, 2.4, blen - 0.6, _shelf, Floor.maxX - 0.35, y, bz);
    const p0x = front - 0.9, p0z = RoofBar.minZ - 0.8, p1x = Floor.maxX - 0.1, p1z = RoofBar.maxZ + 0.8;
    const roofY = 3.3;
    for (final x in [p0x, p1x]) {
      for (final z in [p0z, p1z]) {
        bx(0.16, roofY, 0.16, _pergola, x, y, z);
      }
      bx(0.16, 0.22, p1z - p0z + 0.3, _pergola, x, y + roofY - 0.11, (p0z + p1z) / 2);
    }
    for (var z = p0z; z <= p1z + 0.01; z += 0.55) {
      bx(p1x - p0x + 0.4, 0.08, 0.1, _pergola, (p0x + p1x) / 2, y + roofY + 0.11, z);
    }

    // Parasols along the south edge, over the sun loungers.
    for (final x in [-0.8, 2.0]) {
      const z = Floor.maxZ - 1.1;
      bx(0.08, 2.6, 0.08, _counter, x, y, z);
      parts.add(mesh(cone(1.5, 0.5, 12), _parasol, x, y + 2.6, z, false));
    }
  }

  /// Builds the outside of every floor but [floorIndex], of [count] stacked from the bottom one (0).
  /// A [floorIndex] of [count] is the roof: every floor, below it, and no top (the roof is its own).
  void set(int floorIndex, int count) {
    _built?.detach();
    _built = null;
    for (final c in _mine) {
      _colliders.remove(c);
    }
    _mine.clear();
    _seed = 20260927;

    final plan = towerPlan(floorIndex, count);
    final parts = Node(name: 'tower-parts');
    for (final (:k, :y0) in plan.floors) {
      for (final side in Side.values) {
        final holes = [
          ...windows.where((o) => o.wall == side),
          if (side == Side.south) balconyDoor,
          // Only the bottom floor has a way out on the west side; its door stands in the hole.
          if (side == Side.west && k == 0) exitDoor,
        ];
        _facade(parts, side, y0, holes);
      }
      for (final o in windows) {
        _glazing(parts, o, y0, false);
      }
      _glazing(parts, balconyDoor, y0, true);
      _balcony(parts, y0);
      if (k == 0) {
        // Dark behind the exit door, through its porthole.
        parts.add(
          place(
            mesh(planeXY(exitDoor.width, exitDoor.y1), _behind, 0, 0, 0, false),
            x: Floor.minX - 0.02,
            y: y0 + exitDoor.y1 / 2,
            z: exitDoor.u,
            rot: yaw(-math.pi / 2),
          ),
        );
      }
    }
    // On top, a cornice, and the rooftop bar over it; but up on the roof, it's the roof's own.
    final top = plan.top;
    if (top != null) {
      _crown(parts, top);
      _roofTop(parts, top + slab);
    }
    final merged = mergeByMaterial(parts);
    group.add(merged);
    _built = merged;
    _mine.addAll(towerColliders(floorIndex, count));
    _colliders.addAll(_mine);
  }
}

/// The rest of the building; its colliders go in [colliders] and change as floors come and go.
Tower buildTower(List<Collider> colliders, NightParts night) => Tower._(colliders, night);
