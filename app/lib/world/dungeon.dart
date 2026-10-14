// A dungeon under a hall (see office_shared's maps/dungeon.dart): the vault dug out below the hall's
// floor, the stairs down into it through a hole in that floor with a stone rail round it, and the
// cells along its walls, iron bars across their fronts and a barred door in the middle of each.
// Whoever's locked up in them is the jail's to show (jail.dart); the torches, and the Kingsguard who
// brings them down, are the castle's (castle/). A port of world/dungeon.ts.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/dungeon.dart' show dungeonPillar;
import 'package:office_shared/maps/props.dart' show boxFootprint;
import 'package:office_shared/maps/types.dart' show DungeonPlan;
import 'package:office_shared/nav.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'collider.dart';
import 'geo.dart' as g3;
import 'office/geo.dart' show cyl, yaw;
import 'toon.dart';
import 'world.dart' show DungeonSite;

/// What the dungeon's built with, from the hall it's under.
class DungeonKit {
  DungeonKit({
    required this.group,
    required this.still,
    required this.colliders,
    required this.stone,
    required this.stoneDark,
    required this.iron,
    required this.woodDark,
    required this.wall,
    required this.flags,
  });

  final Node group;

  /// Merged into a few draw calls: whatever never moves.
  final Node still;
  final List<Collider> colliders;
  final Material stone, stoneDark, iron, woodDark;

  /// Dressed stone for a wall (its pictures tile every 4 by 2 meters: see [slab]'s `tiled`), and
  /// flagstones for a floor (every 4 meters).
  final Material wall;
  final Material flags;
}

/// How high the cells' bars go; there's stone over them up to the ceiling.
const double _bars = 2.5;
const double _barGap = 0.2;

/// A cell door, across.
const double _door = 1.1;

/// The stone rail round the hole in the hall's floor.
const ({double height, double thick}) _rail = (height: 0.95, thick: 0.2);

/// The low wall down the open side of the stairs.
const ({double height, double thick}) _parapet = (height: 0.9, thick: 0.15);
const double _wallT = 0.5;

/// A box the size of [r], from [y0] up to [y1]; [tiled] wraps its picture every 4 by 2 meters.
Node slab(NavRect r, double y0, double y1, Material mat, {bool shadow = true, bool tiled = false}) {
  final (x0, x1, z0, z1) = r;
  final geo = tiled ? texturedBox(x1 - x0, y1 - y0, z1 - z0) : g3.box(x1 - x0, y1 - y0, z1 - z0);
  return mesh(geo, mat, (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2, shadow);
}

Float32List _f32(List<double> v) => Float32List.fromList(v);

/// A box whose faces tile a picture every [tileU] by [tileV] meters (three's BoxGeometry with a
/// repeated texture).
Geometry texturedBox(double w, double h, double d, {double tileU = 4, double tileV = 2}) {
  final hx = w / 2, hy = h / 2, hz = d / 2;
  final p = <double>[], n = <double>[], uv = <double>[];
  void face(vm.Vector3 c, vm.Vector3 r, vm.Vector3 u, double sizeU, double sizeV) {
    final normal = r.cross(u)..normalize();
    final su = sizeU / tileU, sv = sizeV / tileV;
    final bl = c - r - u, br = c + r - u, tr = c + r + u, tl = c - r + u;
    for (final (v, a, b) in [
      (bl, 0.0, sv),
      (br, su, sv),
      (tr, su, 0.0),
      (bl, 0.0, sv),
      (tr, su, 0.0),
      (tl, 0.0, 0.0),
    ]) {
      p.addAll([v.x, v.y, v.z]);
      n.addAll([normal.x, normal.y, normal.z]);
      uv.addAll([a, b]);
    }
  }

  face(vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, -hz), vm.Vector3(0, hy, 0), d, h);
  face(vm.Vector3(-hx, 0, 0), vm.Vector3(0, 0, hz), vm.Vector3(0, hy, 0), d, h);
  face(vm.Vector3(0, hy, 0), vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, -hz), w, d);
  face(vm.Vector3(0, -hy, 0), vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, hz), w, d);
  face(vm.Vector3(0, 0, hz), vm.Vector3(hx, 0, 0), vm.Vector3(0, hy, 0), w, h);
  face(vm.Vector3(0, 0, -hz), vm.Vector3(-hx, 0, 0), vm.Vector3(0, hy, 0), w, h);
  return MeshGeometry.fromMeshData(MeshData.build(positions: _f32(p), normals: _f32(n), texCoords: _f32(uv)));
}

/// A flat rectangle at height [y] with a rectangular hole in it (or none), facing up (or [down]). Its
/// picture tiles every [tile] meters, lined up with the world's x and z.
Node holedPlane(NavRect outer, NavRect? hole, double y, Material mat, {bool down = false, double tile = 4}) {
  final (x0, x1, z0, z1) = outer;
  final rects = <NavRect>[];
  if (hole == null) {
    rects.add(outer);
  } else {
    final (h0, h1, k0, k1) = hole;
    rects.addAll([(x0, x1, z0, k0), (x0, x1, k1, z1), (x0, h0, k0, k1), (h1, x1, k0, k1)]);
  }
  final p = <double>[], n = <double>[], uv = <double>[];
  final ny = down ? -1.0 : 1.0;
  for (final (a0, a1, b0, b1) in rects) {
    if (a1 - a0 <= 1e-6 || b1 - b0 <= 1e-6) continue;
    // Counter-clockwise seen from the side it faces.
    final corners = down
        ? [(a0, b0), (a1, b0), (a1, b1), (a0, b0), (a1, b1), (a0, b1)]
        : [(a0, b0), (a0, b1), (a1, b1), (a0, b0), (a1, b1), (a1, b0)];
    for (final (x, z) in corners) {
      p.addAll([x, 0, z]);
      n.addAll([0, ny, 0]);
      uv.addAll([x / tile, z / tile]);
    }
  }
  final geo = MeshGeometry.fromMeshData(MeshData.build(positions: _f32(p), normals: _f32(n), texCoords: _f32(uv)));
  return mesh(geo, mat, 0, y, 0, false);
}

/// The dungeon, built: see [DungeonSite].
class DungeonView implements DungeonSite {
  DungeonView._(this.plan, this.nav, this.inside, this._doors, this.lamps);

  @override
  final DungeonPlan plan;
  @override
  final NavGrid nav;

  /// What's only worth drawing while someone might see it: down there, or looking down the stairs.
  /// Whoever's locked up goes in here.
  @override
  final Node inside;
  final List<({Node leaf, vm.Vector3 lock})> _doors;
  @override
  final List<vm.Vector3> lamps;

  /// Swings cell [i]'s door: 0 shut, 1 wide open.
  @override
  void swing(int i, double open) {
    if (i < 0 || i >= _doors.length) return;
    final e = open * open * (3 - 2 * open);
    _doors[i].leaf.rotation = yaw(-e * 1.75);
  }

  /// Where cell [i]'s lock is, to hear it.
  @override
  vm.Vector3 lock(int i) => i >= 0 && i < _doors.length ? _doors[i].lock.clone() : vm.Vector3.zero();
}

/// Straw strewn on a cell's floor.
final Material _straw = toon(hex('#8f7c48'));
final Material _strawDark = toon(hex('#6d5e36'));

DungeonView buildDungeon(DungeonKit kit, DungeonPlan d) {
  final still = kit.still, colliders = kit.colliders;
  final b = d.bounds;
  final NavRect vault = (b.minX, b.maxX, b.minZ, b.maxZ);
  final h = d.ceiling - d.floor;
  final inside = Node(name: 'dungeon-inside');
  kit.group.add(inside);

  // The floor, and the ceiling: the underside of the hall's floor, with the hole the stairs come down through.
  kit.group.add(holedPlane(vault, null, d.floor, kit.flags));
  colliders.add(Collider(minX: b.minX, maxX: b.maxX, minZ: b.minZ, maxZ: b.maxZ, top: d.floor, bottom: d.floor - 0.3));
  kit.group.add(holedPlane(vault, d.opening, d.ceiling, kit.stoneDark, down: true));
  // Beams across under it, clear of the stairs.
  final (o0, o1, p0, p1) = d.opening;
  for (var z = b.minZ + 1.6; z < b.maxZ - 0.5; z += 2.6) {
    final spans = z > p0 - 0.2 && z < p1 + 0.2 ? [(b.minX, o0), (o1, b.maxX)] : [(b.minX, b.maxX)];
    for (final (a, c) in spans) {
      if (c - a > 0.3)
        still.add(slab((a, c, z - 0.16, z + 0.16), d.ceiling - 0.32, d.ceiling, kit.woodDark, shadow: false));
    }
  }

  // The walls round the vault, from its floor up to the hall's.
  final walls = <NavRect>[
    (b.minX - _wallT, b.minX, b.minZ - _wallT, b.maxZ + _wallT),
    (b.maxX, b.maxX + _wallT, b.minZ - _wallT, b.maxZ + _wallT),
    (b.minX, b.maxX, b.minZ - _wallT, b.minZ),
    (b.minX, b.maxX, b.maxZ, b.maxZ + _wallT),
  ];
  for (final r in walls) {
    kit.group.add(slab(r, d.floor, 0, kit.wall, tiled: true));
    colliders.add(Collider(minX: r.$1, maxX: r.$2, minZ: r.$3, maxZ: r.$4, top: d.ceiling, bottom: d.floor));
  }
  // The rim of the hole in the hall's floor, so you can't see into it.
  for (final r in <NavRect>[
    (o0 - 0.05, o0, p0, p1),
    (o1, o1 + 0.05, p0, p1),
    (o0, o1, p0 - 0.05, p0),
    (o0, o1, p1, p1 + 0.05),
  ]) {
    still.add(slab(r, d.ceiling, 0, kit.stoneDark, shadow: false));
  }

  // The stone rail round the hole, on every side but the one the stairs start from.
  final along = (math.sin(d.stairs.rotY).roundToDouble(), math.cos(d.stairs.rotY).roundToDouble());
  final (r0, r1, q0, q1) = d.rails;
  final sides = <({NavRect rect, bool start})>[
    (rect: (r0, o0, q0, q1), start: along.$1 > 0),
    (rect: (o1, r1, q0, q1), start: along.$1 < 0),
    (rect: (r0, r1, q0, p0), start: along.$2 > 0),
    (rect: (r0, r1, p1, q1), start: along.$2 < 0),
  ];
  for (final s in sides) {
    if (s.start) continue;
    final r = s.rect;
    still.add(slab(r, 0, _rail.height - 0.1, kit.stone));
    still.add(
      slab((r.$1 - 0.04, r.$2 + 0.04, r.$3 - 0.04, r.$4 + 0.04), _rail.height - 0.1, _rail.height, kit.stoneDark),
    );
    colliders.add(Collider(minX: r.$1, maxX: r.$2, minZ: r.$3, maxZ: r.$4, top: _rail.height, fence: true));
  }

  // The stairs: each step a block of stone from the vault's floor up, and a low wall down whichever
  // side of them is open to the vault.
  final across = (math.cos(d.stairs.rotY), -math.sin(d.stairs.rotY));
  final openSides = [
    for (final s in const [-1, 1])
      if (!() {
        final ex = d.stairs.start.$1 + across.$1 * s * (d.stairs.width / 2);
        final ez = d.stairs.start.$2 + across.$2 * s * (d.stairs.width / 2);
        return across.$1.abs() > 0.5
            ? (ex - b.minX).abs() < 0.05 || (ex - b.maxX).abs() < 0.05
            : (ez - b.minZ).abs() < 0.05 || (ez - b.maxZ).abs() < 0.05;
      }())
        s,
  ];
  // How deep a step is: along the way down.
  final first = d.steps[0].rect;
  final tread = along.$1.abs() > 0 ? first.$2 - first.$1 : first.$4 - first.$3;
  for (var i = 0; i < d.steps.length; i++) {
    final s = d.steps[i];
    final r = s.rect;
    still.add(slab(r, d.floor, s.top, i.isOdd ? kit.stone : kit.stoneDark));
    colliders.add(Collider(minX: r.$1, maxX: r.$2, minZ: r.$3, maxZ: r.$4, top: s.top, bottom: d.floor));
    final cx = (r.$1 + r.$2) / 2, cz = (r.$3 + r.$4) / 2;
    // (The last step is the vault's floor: nothing to fall off there.)
    for (final side in i < d.steps.length - 1 ? openSides : const <int>[]) {
      final px = cx + across.$1 * side * (d.stairs.width / 2 - _parapet.thick / 2);
      final pz = cz + across.$2 * side * (d.stairs.width / 2 - _parapet.thick / 2);
      final w = boxFootprint(px, pz, _parapet.thick, tread + 0.01, d.stairs.rotY);
      still.add(slab(w, s.top, s.top + _parapet.height, kit.stoneDark));
      colliders.add(
        Collider(
          minX: w.$1,
          maxX: w.$2,
          minZ: w.$3,
          maxZ: w.$4,
          top: s.top + _parapet.height,
          bottom: d.floor,
          fence: true,
        ),
      );
    }
  }

  // The cells: bars across the front with a door in the middle, stone over the bars, walls between.
  final built = <NavRect>[];
  // A wall along the vault's own (a cell's back, or the side of the one at the end of a row) is there already.
  bool onVaultWall(NavRect r) {
    final cx = (r.$1 + r.$2) / 2, cz = (r.$3 + r.$4) / 2;
    return r.$2 - r.$1 < r.$4 - r.$3
        ? math.min((cx - b.minX).abs(), (cx - b.maxX).abs()) < 0.2
        : math.min((cz - b.minZ).abs(), (cz - b.maxZ).abs()) < 0.2;
  }

  bool same(NavRect a, NavRect c) =>
      (a.$1 - c.$1).abs() < 0.05 &&
      (a.$2 - c.$2).abs() < 0.05 &&
      (a.$3 - c.$3).abs() < 0.05 &&
      (a.$4 - c.$4).abs() < 0.05;
  void stoneWall(NavRect r) {
    // Two cells side by side share the wall between them.
    if (onVaultWall(r) || built.any((o) => same(o, r))) return;
    built.add(r);
    kit.group.add(slab(r, d.floor, d.ceiling, kit.wall, tiled: true));
    colliders.add(Collider(minX: r.$1, maxX: r.$2, minZ: r.$3, maxZ: r.$4, top: d.ceiling, bottom: d.floor));
  }

  final doors = <({Node leaf, vm.Vector3 lock})>[];
  final bars = cyl(0.025, 0.025, _bars - 0.05, 6);
  for (final c in d.cells) {
    final out = (math.sin(c.rotY), math.cos(c.rotY));
    final acr = (math.cos(c.rotY), -math.sin(c.rotY));
    (double, double) at(double u, double v) => (c.x + acr.$1 * u - out.$1 * v, c.z + acr.$2 * u - out.$2 * v);
    // Its side walls, and its back wall if it isn't the vault's.
    for (final s in const [-1, 1]) {
      final (mx, mz) = at(s * c.width / 2, c.depth / 2);
      stoneWall(boxFootprint(mx, mz, 0.3, c.depth, c.rotY));
    }
    final (bx, bz) = at(0, c.depth);
    stoneWall(boxFootprint(bx, bz, c.width + 0.3, 0.3, c.rotY));
    // The front: stone over the bars, the bars either side of the door, and bands across them.
    final front = Node(name: 'cell-front')
      ..position = vm.Vector3(c.x, d.floor, c.z)
      ..rotation = yaw(c.rotY);
    front.add(mesh(texturedBox(c.width + 0.3, h - _bars, 0.3), kit.wall, 0, _bars + (h - _bars) / 2, 0));
    final half = c.width / 2;
    for (final (a, z) in [(-half, -_door / 2), (_door / 2, half)]) {
      for (var u = a + _barGap / 2; u < z - 0.02; u += _barGap) {
        front.add(mesh(bars, kit.iron, u, _bars / 2, 0, false));
      }
      for (final y in const [0.12, 1.25, _bars - 0.06]) {
        front.add(mesh(g3.box(z - a, 0.07, 0.07), kit.iron, (a + z) / 2, y, 0, false));
      }
    }
    // Posts either side of the door.
    for (final s in const [-1, 1]) {
      front.add(mesh(g3.box(0.12, _bars, 0.12), kit.iron, s * (_door + 0.12) / 2, _bars / 2, 0, false));
    }
    // The stone over the bars has a picture: it isn't merged (merging drops pictures' coordinates).
    kit.group.add(front);
    // The door, hung on its left post, swinging out into the vault.
    final hinge = Node(name: 'cell-door')
      ..position = vm.Vector3(c.x - acr.$1 * (_door / 2), d.floor, c.z - acr.$2 * (_door / 2))
      ..rotation = yaw(c.rotY);
    final leaf = Node(name: 'leaf');
    for (var u = _barGap / 2 + 0.03; u < _door - 0.03; u += _barGap) {
      leaf.add(mesh(bars, kit.iron, u, _bars / 2 - 0.05, 0, false));
    }
    for (final y in const [0.15, 1.25, _bars - 0.12]) {
      leaf.add(mesh(g3.box(_door, 0.08, 0.08), kit.iron, _door / 2, y, 0, false));
    }
    // The lock, and a ring to pull it by.
    leaf.add(mesh(g3.box(0.18, 0.24, 0.12), kit.iron, _door - 0.12, 1.1, 0.02, false));
    leaf.add(mesh(g3.torus(0.07, 0.015, 6, 12), kit.iron, _door - 0.12, 0.95, 0.1, false));
    hinge.add(leaf);
    kit.group.add(hinge);
    final (lx, lz) = at(_door / 2 - 0.12, 0);
    doors.add((leaf: leaf, lock: vm.Vector3(lx, d.floor + 1.1, lz)));
    final fr = boxFootprint(c.x, c.z, c.width, 0.24, c.rotY);
    colliders.add(Collider(minX: fr.$1, maxX: fr.$2, minZ: fr.$3, maxZ: fr.$4, top: d.ceiling, bottom: d.floor));

    // Straw on the floor, and shackles on the back wall.
    for (var k = 0; k < 3; k++) {
      final (sx, sz) = at((k - 1) * c.width * 0.28, c.depth * (0.45 + 0.18 * (k % 2)));
      final r = 0.55 + 0.2 * (k % 2);
      inside.add(
        mesh(g3.cylinder(r, r, 0.004, 9), k.isOdd ? _strawDark : _straw, sx, d.floor + 0.012 + k * 0.002, sz, false)
          ..rotation = yaw(k * 1.3)
          ..scale = vm.Vector3(1.3, 1, 0.8),
      );
    }
    for (final s in const [-1, 1]) {
      final (kx, kz) = at(s * math.min(1.1, c.width / 4), c.depth - 0.18);
      final shackle = Node(name: 'shackle')
        ..position = vm.Vector3(kx, d.floor + 1.55, kz)
        ..rotation = yaw(c.rotY);
      shackle.add(mesh(g3.box(0.14, 0.14, 0.05), kit.iron, 0, 0, 0, false));
      for (var l = 0; l < 4; l++) {
        shackle.add(
          mesh(g3.torus(0.045, 0.012, 5, 10), kit.iron, 0, -0.08 - l * 0.075, 0.05, false)
            ..rotation = yaw(l.isOdd ? math.pi / 2 : 0),
        );
      }
      shackle.add(mesh(g3.torus(0.08, 0.02, 6, 12), kit.iron, 0, -0.42, 0.06, false));
      inside.add(shackle);
    }
  }

  // Pillars holding the vault up.
  for (final (px, pz) in d.pillars) {
    const w = dungeonPillar;
    still.add(mesh(g3.box(w + 0.16, 0.4, w + 0.16), kit.stoneDark, px, d.floor + 0.2, pz));
    kit.group.add(mesh(texturedBox(w, h - 0.8, w), kit.wall, px, d.floor + 0.4 + (h - 0.8) / 2, pz));
    still.add(mesh(g3.box(w + 0.2, 0.4, w + 0.2), kit.stoneDark, px, d.ceiling - 0.2, pz));
    colliders.add(
      Collider(minX: px - w / 2, maxX: px + w / 2, minZ: pz - w / 2, maxZ: pz + w / 2, top: d.ceiling, bottom: d.floor),
    );
  }

  final lamps = [
    for (final t in d.torches)
      vm.Vector3(t.x + math.sin(t.rotY) * 0.5, d.floor + 2.3 + 0.9, t.z + math.cos(t.rotY) * 0.5),
  ];
  return DungeonView._(d, NavGrid(d.bounds, d.obstacles), inside, doors, lamps);
}
