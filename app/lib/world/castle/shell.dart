// The shell of the hall: the floor, the four walls (a doorway in the one nearest the map's door,
// with its great doors), and the timber roof. A port of world/castle/shell.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart' show MapPlan;
import 'package:office_shared/nav.dart' show NavRect, Pt;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../dungeon.dart' show holedPlane, texturedBox;
import '../geo.dart' as g3;
import '../office/geo.dart' show Shape2, extrudeShape, transformed, yaw;
import '../toon.dart';
import 'kit.dart';
import 'shapes.dart';
import 'textures.dart';

/// Where the doorway is, which way is out through it, and how to swing the doors (0 shut, 1 open).
typedef Shell = ({vm.Vector3 doorAt, Pt out, void Function(double open) swing});

Shell buildShell(Kit kit, MapPlan plan, {required String floorColor, required String stoneColor}) {
  final b = plan.bounds;
  final h = plan.height;
  final w = b.maxX - b.minX;
  final l = b.maxZ - b.minZ;
  final group = kit.group, still = kit.still, mats = kit.mats;
  final hole = plan.dungeon?.opening;
  final flags = texToon(painted(512, 512, flagstones(floorColor)));
  final NavRect hall = (b.minX, b.maxX, b.minZ, b.maxZ);
  if (hole != null) {
    // A hole in the floor over the dungeon stairs, and the floor round it is the dungeon's ceiling.
    group.add(holedPlane(hall, hole, 0, flags));
    final (h0, h1, k0, k1) = hole;
    final bottom = plan.dungeon!.ceiling;
    for (final (x0, x1, z0, z1) in [
      (b.minX - 1, h0, b.minZ - 1, b.maxZ + 1),
      (h1, b.maxX + 1, b.minZ - 1, b.maxZ + 1),
      (h0, h1, b.minZ - 1, k0),
      (h0, h1, k1, b.maxZ + 1),
    ]) {
      kit.colliders.add(Collider(minX: x0, maxX: x1, minZ: z0, maxZ: z1, top: 0, bottom: bottom));
    }
  } else {
    group.add(holedPlane(hall, null, 0, flags));
    kit.colliders.add(Collider(minX: b.minX - 1, maxX: b.maxX + 1, minZ: b.minZ - 1, maxZ: b.maxZ + 1, top: 0));
  }

  // Which wall the doors are in: the one nearest the door.
  final door = plan.door;
  final gaps = {'west': door.x - b.minX, 'east': b.maxX - door.x, 'north': door.z - b.minZ, 'south': b.maxZ - door.z};
  final doorWall = gaps.keys.fold('south', (a, k) => gaps[k]! < gaps[a]! ? k : a);
  final Pt out = switch (doorWall) {
    'west' => (-1, 0),
    'east' => (1, 0),
    'north' => (0, -1),
    _ => (0, 1),
  };
  const t = castleWall;
  final stone = texToon(painted(512, 256, ashlar(stoneColor, 5)));
  final walls = <(String, double, double, double, double)>[
    ('west', b.minX - t / 2, (b.minZ + b.maxZ) / 2, t, l + 2 * t),
    ('east', b.maxX + t / 2, (b.minZ + b.maxZ) / 2, t, l + 2 * t),
    ('north', (b.minX + b.maxX) / 2, b.minZ - t / 2, w, t),
    ('south', (b.minX + b.maxX) / 2, b.maxZ + t / 2, w, t),
  ];
  for (final (side, x, z, ww, d) in walls) {
    final alongX = side == 'north' || side == 'south';
    if (side != doorWall) {
      group.add(mesh(texturedBox(ww, h, d), stone, x, h / 2, z));
      kit.colliders.add(Collider(minX: x - ww / 2, maxX: x + ww / 2, minZ: z - d / 2, maxZ: z + d / 2, top: 99));
      continue;
    }
    // A doorway through this one: the wall either side of it, and over it.
    final u = alongX ? door.x : door.z;
    final lo = alongX ? x - ww / 2 : z - d / 2;
    final hi = alongX ? x + ww / 2 : z + d / 2;
    final d0 = u - doorway.width / 2;
    final d1 = u + doorway.width / 2;
    for (final (a, bb) in [(lo, d0), (d1, hi)]) {
      final m = (a + bb) / 2;
      final span = bb - a;
      if (span <= 0) continue;
      group.add(
        alongX ? mesh(texturedBox(span, h, d), stone, m, h / 2, z) : mesh(texturedBox(ww, h, span), stone, x, h / 2, m),
      );
      kit.colliders.add(
        alongX
            ? Collider(minX: a, maxX: bb, minZ: z - d / 2, maxZ: z + d / 2, top: 99)
            : Collider(minX: x - ww / 2, maxX: x + ww / 2, minZ: a, maxZ: bb, top: 99),
      );
    }
    group.add(
      alongX
          ? mesh(texturedBox(doorway.width, h - doorway.height, d), stone, u, (h + doorway.height) / 2, z)
          : mesh(texturedBox(ww, h - doorway.height, doorway.width), stone, x, (h + doorway.height) / 2, u),
    );
    // The workers come and go through it; you stay in the hall.
    kit.colliders.add(
      alongX
          ? Collider(minX: d0, maxX: d1, minZ: z - d / 2, maxZ: z + d / 2, top: 99, fence: true)
          : Collider(minX: x - ww / 2, maxX: x + ww / 2, minZ: d0, maxZ: d1, top: 99, fence: true),
    );
  }
  // Skirting and a cornice round the room.
  for (final (side, x, z, ww, d) in walls) {
    final alongX = side == 'north' || side == 'south';
    final inset = alongX
        ? (0.0, (side == 'north' ? 1 : -1) * (t / 2 + 0.06))
        : ((side == 'west' ? 1 : -1) * (t / 2 + 0.06), 0.0);
    final len = alongX ? ww : d;
    still.add(
      mesh(
        alongX ? g3.box(len, 0.5, 0.14) : g3.box(0.14, 0.5, len),
        mats.stoneDark,
        x + inset.$1,
        0.25,
        z + inset.$2,
        false,
      ),
    );
    still.add(
      mesh(
        alongX ? g3.box(len, 0.35, 0.24) : g3.box(0.24, 0.35, len),
        mats.stoneDark,
        x + inset.$1,
        h - 0.2,
        z + inset.$2,
        false,
      ),
    );
  }
  // Outside the doors: a landing, so workers have somewhere to walk off to, and the grass beyond.
  final lx = doorWall == 'west' ? b.minX - 3 : (doorWall == 'east' ? b.maxX + 3 : door.x);
  final lz = doorWall == 'north' ? b.minZ - 3 : (doorWall == 'south' ? b.maxZ + 3 : door.z);
  final sideways = out.$1 != 0;
  group.add(mesh(g3.box(sideways ? 6 : 7, 0.2, sideways ? 7 : 6), mats.stoneDark, lx, -0.1, lz));
  kit.colliders.add(Collider(minX: lx - 3.5, maxX: lx + 3.5, minZ: lz - 3.5, maxZ: lz + 3.5, top: 0));
  // Round the hall, not under it, where it'd show through the hole down to the dungeon.
  final cx = (b.minX + b.maxX) / 2, cz = (b.minZ + b.maxZ) / 2;
  group.add(
    holedPlane(
      (cx - 120, cx + 120, cz - 120, cz + 120),
      hole != null ? (b.minX - t, b.maxX + t, b.minZ - t, b.maxZ + t) : null,
      -0.25,
      tc('#5d7a3a'),
    ),
  );

  // The great doors, swinging in when someone comes up to them.
  final leaves = <Node>[];
  final doorAt = vm.Vector3(
    doorWall == 'west' ? b.minX : (doorWall == 'east' ? b.maxX : door.x),
    0,
    doorWall == 'north' ? b.minZ : (doorWall == 'south' ? b.maxZ : door.z),
  );
  final frame = Node(name: 'doors')
    ..position = doorAt
    ..rotation = yaw(math.atan2(out.$1, out.$2));
  final r = doorway.width * 0.7;
  final feet = doorway.height - archRise(doorway.width, r);
  // Each leaf is half the arch: square up to where the arch springs, then following its curve up to the point.
  final arc = Shape2(12)..moveTo(-doorway.width / 2, 0);
  archPath(arc, doorway.width, r, 0);
  final curve = arc.points.where((v) => v.x <= 0.001).toList();
  List<vm.Vector2> half(double flip) => [
    vm.Vector2(0, 0),
    vm.Vector2(flip * doorway.width / 2, 0),
    for (final v in curve.reversed) vm.Vector2(flip * (v.x + doorway.width / 2), v.y + feet),
  ];
  Geometry leafGeo(double flip) {
    final s = Shape2(12);
    final pts = half(flip);
    s.moveTo(pts.first.x, pts.first.y);
    for (final p in pts.skip(1)) {
      s.lineTo(p.x, p.y);
    }
    return transformed(extrudeShape(s, 0.16), vm.Matrix4.translationValues(0, 0, -0.08));
  }

  final oak = tc('#4a2d18');
  for (final side in const [-1, 1]) {
    // The right one is the left one turned over (three's scale.x = -side, built mirrored here).
    final flip = -side.toDouble();
    final hinge = Node(name: 'hinge')..position = vm.Vector3(side * (doorway.width / 2), 0, 0.1);
    final leaf = Node(name: 'leaf');
    leaf.add(mesh(leafGeo(flip), oak));
    for (final y in const [1.1, 2.6]) {
      leaf.add(mesh(g3.box(doorway.width / 2 - 0.1, 0.12, 0.2), mats.iron, flip * doorway.width / 4, y, 0, false));
    }
    leaf.add(mesh(g3.torus(0.16, 0.035, 6, 14), mats.iron, flip * (doorway.width / 2 - 0.35), 2.0, -0.12, false));
    hinge.add(leaf);
    frame.add(hinge);
    leaves.add(hinge);
  }
  // A pointed arch of stone over the doorway, filling it in above the arch, and the jambs under it.
  frame.add(
    mesh(
      archFill(doorway.width + 1, doorway.height - feet + 0.4, doorway.width, t + 0.24, r),
      mats.stoneDark,
      0,
      feet,
      t / 2,
    ),
  );
  for (final sx in const [-1, 1]) {
    frame.add(mesh(g3.box(0.5, feet, t + 0.24), mats.stoneDark, sx * (doorway.width / 2 + 0.25), feet / 2, t / 2));
  }
  group.add(frame);

  // The roof: a truss across the hall over each pair of pillars, and boarding over them up to the ridge.
  final rise = w * 0.3;
  final pitch = math.atan2(rise, w / 2);
  final roofWood = texToon(painted(256, 256, boards('#3b2618')));
  for (final side in const [-1, 1]) {
    group.add(
      mesh(
        texturedBox(math.sqrt(w * w / 4 + rise * rise) + 0.8, 0.25, l + 2 * t, tileV: 4),
        roofWood,
        side * w / 4,
        h + rise / 2,
        cz,
        false,
      )..rotation = g3.euler(0, 0, -side * pitch),
    );
  }
  // The gables at either end.
  for (final z in [b.minZ - t / 2, b.maxZ + t / 2]) {
    final tri = Shape2()
      ..moveTo(-w / 2 - t, 0)
      ..lineTo(w / 2 + t, 0)
      ..lineTo(0, rise + 0.2);
    group.add(mesh(extrudeShape(tri, t), mats.stone, cx, h, z - t / 2, false));
  }
  // Over the pillars, where there are pillars, else every 6 m.
  final props = (plan.config?['props'] as List?) ?? const [];
  final pillarZs = {
    for (final q in props)
      if (q is Map && q['kind'] == 'pillar' && q['z'] is num) ((q['z'] as num) * 10).round() / 10,
  }.toList()..sort();
  final trussZs = pillarZs.length >= 2 ? pillarZs : <double>[];
  if (trussZs.isEmpty) {
    for (var z = b.minZ + 3; z < b.maxZ - 1; z += 6) {
      trussZs.add(z);
    }
  }
  final rafterLen = math.sqrt(w * w / 4 + rise * rise);
  final strutLen = math.sqrt(w * w / 16 + rise * rise / 4);
  for (final z in trussZs) {
    final tr = Node(name: 'truss')..position = vm.Vector3(cx, 0, z);
    tr.add(mesh(g3.box(w, 0.45, 0.4), mats.woodDark, 0, h - 0.1, 0, false));
    tr.add(mesh(g3.box(0.35, rise, 0.35), mats.woodDark, 0, h + rise / 2, 0, false));
    for (final side in const [-1, 1]) {
      tr.add(
        mesh(g3.box(rafterLen, 0.35, 0.35), mats.woodDark, side * w / 4, h + rise / 2 - 0.15, 0, false)
          ..rotation = g3.euler(0, 0, -side * pitch),
      );
      tr.add(
        mesh(g3.box(strutLen, 0.25, 0.3), mats.woodDark, side * w / 8, h + rise / 4, 0, false)
          ..rotation = g3.euler(0, 0, side * math.atan2(rise / 2, w / 4)),
      );
    }
    still.add(tr);
  }
  still.add(mesh(g3.box(0.4, 0.4, l), mats.woodDark, cx, h + rise - 0.3, cz, false));

  return (
    doorAt: doorAt,
    out: out,
    swing: (double open) {
      final e = open * open * (3 - 2 * open);
      for (var i = 0; i < leaves.length; i++) {
        leaves[i].rotation = yaw((i > 0 ? -1 : 1) * e * 1.4);
      }
    },
  );
}
