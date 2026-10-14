// The station's shell: the deck, the hull's four walls with the windows, the way in and the airlock's
// door cut through them, the ceiling, the hatch workers come and go by with the docking tunnel beyond
// it, and what shows of the station from its windows: its solar wings. A port of world/station/shell.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/airlock.dart' show HatchSize, hullThickness, wallOut;
import 'package:office_shared/maps/maps.dart' show MapPlan;
import 'package:office_shared/maps/types.dart' show OpeningKind, WallOpening, WallSide;
import 'package:office_shared/nav.dart' show Bounds, Pt;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../geo.dart' as g3;
import '../office/geo.dart' show planeXY, planeXYuv, yaw;
import '../office/parts.dart' show canvasTexture;
import '../text.dart';
import '../toon.dart';
import 'kit.dart';
import 'textures.dart';

const List<WallSide> _sides = [WallSide.west, WallSide.east, WallSide.north, WallSide.south];

/// A wall as somewhere to build: `at(u, d)` is the point [u] along it and [d] out through it from its
/// inside face.
class WallFrame {
  WallFrame(Bounds b, this.side)
    : out = wallOut(side),
      alongX = side == WallSide.north || side == WallSide.south,
      _face = switch (side) {
        WallSide.west => b.minX,
        WallSide.east => b.maxX,
        WallSide.north => b.minZ,
        WallSide.south => b.maxZ,
      };

  final WallSide side;
  final Pt out;
  final bool alongX;
  final double _face;

  /// Turned so +z is the way out through it, and +x runs along it.
  double get rotY => math.atan2(out.$1, out.$2);

  Pt at(double u, double d) => alongX ? (u, _face + out.$2 * d) : (_face + out.$1 * d, u);

  /// A box [su] along the wall, [h] high and [sd] through it.
  Geometry box(double su, double h, double sd) => alongX ? g3.box(su, h, sd) : g3.box(sd, h, su);
}

/// Where the way in is, which way is out through it, and how to slide its doors (0 shut, 1 open).
typedef Shell = ({vm.Vector3 doorAt, Pt out, void Function(double open) slide});

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

/// Puts up the shell.
Shell buildShell(Kit kit, {required String hull, required String deck}) {
  final plan = kit.plan, group = kit.group, still = kit.still, mats = kit.mats;
  final b = plan.bounds;
  final h = plan.height;
  const t = hullThickness;
  final w = b.maxX - b.minX, l = b.maxZ - b.minZ;
  final cx = (b.minX + b.maxX) / 2, cz = (b.minZ + b.maxZ) / 2;
  final openings = plan.openings ?? const <WallOpening>[];
  final hullMat = texToon(canvasTexture(512, 512, hullPanels(hull)));
  final pieces = Batch();

  // The deck and the ceiling: slabs the size of the hull, so the Sun only gets in by the windows.
  pieces.tileBox(
    w + 2 * t,
    t,
    l + 2 * t,
    plate,
    vm.Vector3(cx, -t / 2, cz),
    texToon(canvasTexture(512, 512, deckPlates(deck))),
  );
  pieces.tileBox(
    w + 2 * t,
    t,
    l + 2 * t,
    panel,
    vm.Vector3(cx, h + t / 2, cz),
    texToon(canvasTexture(256, 256, ceilingPanels('#8d98a8'))),
  );
  kit.colliders.add(Collider(minX: b.minX - 8, maxX: b.maxX + 8, minZ: b.minZ - 8, maxZ: b.maxZ + 8, top: 0));

  for (final side in _sides) {
    final f = WallFrame(b, side);
    // The side walls run past the end walls, to close the corners.
    final (lo, hi) = f.alongX ? (b.minX, b.maxX) : (b.minZ - t, b.maxZ + t);
    void piece(double u0, double u1, double y0, double y1) {
      if (u1 - u0 < 0.01 || y1 - y0 < 0.01) return;
      final (x, z) = f.at((u0 + u1) / 2, t / 2);
      final (pw, pd) = f.alongX ? (u1 - u0, t) : (t, u1 - u0);
      pieces.tileBox(pw, y1 - y0, pd, panel, vm.Vector3(x, (y0 + y1) / 2, z), hullMat);
    }

    final cut = openings.where((o) => o.wall == side).toList()..sort((p, q) => p.u.compareTo(q.u));
    var from = lo;
    for (final o in cut) {
      final a = o.u - o.width / 2, z = o.u + o.width / 2;
      piece(from, a, 0, h);
      piece(a, z, 0, o.y);
      piece(a, z, o.y + o.height, h);
      from = z;
      if (o.kind == OpeningKind.viewport) _viewport(kit, f, o);
    }
    piece(from, hi, 0, h);
    // You stay inside: the windows, the way in and the airlock are the workers' to go through.
    final (x0, z0) = f.at(lo, 0);
    final (x1, z1) = f.at(hi, t);
    kit.colliders.add(
      Collider(
        minX: math.min(x0, x1),
        maxX: math.max(x0, x1),
        minZ: math.min(z0, z1),
        maxZ: math.max(z0, z1),
        top: 99,
        fence: true,
      ),
    );

    // A dark skirting along the foot of it, a line of light on top, broken where there's a door.
    final doors = cut.where((o) => o.kind != OpeningKind.viewport);
    var s = f.alongX ? b.minX : b.minZ;
    final end = f.alongX ? b.maxX : b.maxZ;
    void skirt(double u0, double u1) {
      if (u1 - u0 < 0.05) return;
      final (x, z) = f.at((u0 + u1) / 2, -0.05);
      still.add(_m(f.box(u1 - u0, 0.5, 0.1), mats.metalDark, x, 0.25, z, false));
      final (lx, lz) = f.at((u0 + u1) / 2, -0.11);
      still.add(_m(f.box(u1 - u0, 0.05, 0.03), mats.accent, lx, 0.56, lz, false));
    }

    for (final o in doors) {
      skirt(s, o.u - o.width / 2 - 0.3);
      s = o.u + o.width / 2 + 0.3;
    }
    skirt(s, end);
  }

  // Down each long wall, where it meets the ceiling: a slanted cove, a line of light under it, and a
  // trough of light over the deck.
  for (final sx in const [-1, 1]) {
    still.add(
      _m(g3.box(0.14, 1.7, l), mats.hullDark, cx + sx * (w / 2 - 0.58), h - 0.58, cz, false)
        ..rotation = g3.euler(0, 0, sx * math.pi / 4),
    );
    still.add(_m(g3.box(0.04, 0.07, l), mats.accent, cx + sx * (w / 2 - 0.03), h - 1.22, cz, false));
    still.add(_m(g3.box(0.55, 0.05, l - 5), mats.lamp, cx + sx * (w / 2 - 3.4), h - 0.03, cz, false));
  }
  group.add(pieces.build('hull'));

  // The way in: a hatch whose two doors slide apart into the wall, and the docking tunnel beyond.
  final way = openings.firstWhere((o) => o.kind == OpeningKind.door);
  final f = WallFrame(b, way.wall);
  final (dx, dz) = f.at(way.u, 0);
  final doorAt = vm.Vector3(dx, 0, dz);
  final frame = placed(dx, 0, dz, f.rotY, 'hatch');
  const hw = HatchSize.width, hh = HatchSize.height;
  // Lapping a little into the opening (see _viewport).
  for (final sx in const [-1, 1]) {
    frame.add(_m(g3.box(0.3, hh + 0.3, t + 0.3), mats.metalDark, sx * (hw / 2 + 0.11), (hh + 0.3) / 2, t / 2));
  }
  frame.add(_m(g3.box(hw + 0.6, 0.3, t + 0.3), mats.metalDark, 0, hh + 0.11, t / 2));
  frame.add(
    _m(
      planeXYuv(hw + 0.6, 0.26, 0, 0, hw / 2, 1),
      unlitPicture(canvasTexture(256, 32, hazard)),
      0,
      hh + 0.15,
      -0.16,
      false,
    )..rotation = yaw(math.pi),
  );
  frame.add(
    textPlane('🚀 Docking port', const TextOpts(bg: '#0f1a26', color: '#cfeeff', border: '#3a5a78', size: 56))
      ..position = vm.Vector3(0, hh + 0.75, -0.06)
      ..rotation = yaw(math.pi)
      ..scale = vm.Vector3.all(0.9),
  );
  final leaves = <Node>[];
  for (final sx in const [-1, 1]) {
    final leaf = Node(name: 'leaf')
      ..add(_m(g3.box(hw / 2, hh, 0.16), mats.metal, 0, hh / 2, 0))
      ..add(_m(g3.box(hw / 2 - 0.5, 0.5, 0.2), mats.black, 0, hh * 0.62, 0, false))
      ..add(_m(g3.box(0.06, hh - 0.3, 0.2), mats.accent, -sx * hw / 4 + sx * 0.09, hh / 2, 0, false))
      ..position = vm.Vector3(sx * hw / 4, 0, t / 2);
    frame.add(leaf);
    leaves.add(leaf);
  }
  group.add(frame);
  // The tunnel: somewhere for workers to walk off to, and come in from.
  final tunnel = placed(dx, 0, dz, f.rotY, 'tunnel');
  const len = 6.0;
  tunnel.add(_m(g3.box(hw + 0.8, 0.2, len), mats.metalDark, 0, -0.1, t + len / 2, false));
  tunnel.add(_m(g3.box(hw + 0.8, 0.2, len), mats.hullDark, 0, hh + 0.5, t + len / 2));
  for (final sx in const [-1, 1]) {
    tunnel.add(_m(g3.box(0.2, hh + 0.6, len), mats.hull, sx * (hw / 2 + 0.3), (hh + 0.4) / 2, t + len / 2));
    tunnel.add(_m(g3.box(0.05, 0.08, len - 0.4), mats.lamp, sx * (hw / 2 + 0.17), hh, t + len / 2, false));
  }
  tunnel.add(_m(g3.box(hw + 0.8, hh + 0.6, 0.2), mats.hull, 0, (hh + 0.4) / 2, t + len + 0.1));
  tunnel.add(
    _m(
      g3.cylinderData(1.25, 1.25, 0.16, 28).rotateX(math.pi / 2).build(),
      mats.metal,
      0,
      hh / 2,
      t + len - 0.08,
      false,
    ),
  );
  tunnel.add(_m(g3.torus(1.25, 0.07, 8, 32), mats.accent, 0, hh / 2, t + len - 0.18, false));
  still.add(tunnel);

  // Out of the windows: solar wings off both sides of the hull, a light winking at the tip of each.
  final cells = texToon(canvasTexture(256, 256, solarCells))..doubleSided = true;
  final cellPlane = planeXYuv(3, 2.5, 0, 0, 1, 1);
  final wingZ = [b.minZ + l * 0.2, b.minZ + l * 0.72];
  for (final (sx, z) in [(-1, wingZ[0]), (-1, wingZ[1]), (1, wingZ[0])]) {
    final wing = placed(sx < 0 ? b.minX - t : b.maxX + t, 3.1, z, sx < 0 ? math.pi : 0, 'wing');
    const boom = 21.0;
    wing.add(
      _m(
        g3.cylinderData(0.16, 0.16, boom, 10).transform(vm.Matrix4.rotationZ(math.pi / 2)).build(),
        mats.metal,
        boom / 2,
        0,
        0,
        false,
      ),
    );
    for (var i = 0; i < 5; i++) {
      for (final up in const [-1, 1]) {
        // Tipped back toward the Sun a little, so they catch it.
        wing.add(_m(cellPlane, cells, 5.2 + i * 3.25, up * 1.5, 0, false)..rotation = g3.euler(-0.5, 0));
      }
      wing.add(_m(g3.box(0.08, 5.6, 0.08), mats.metalDark, 3.6 + i * 3.25, 0, 0, false));
    }
    final color = sx < 0 ? '#ff4d4d' : '#3dff8a';
    final tip = lit(color);
    wing.add(_m(g3.sphere(0.22, 10, 8), tip, boom + 0.2, 0, 0, false));
    final on = linear(hex(color));
    kit.pulses.add(Pulse((k) => tip.baseColorFactor = on.clone()..scale(k > 0.8 ? 1 : 0.12), 0.7, sx < 0 ? 0 : 0.5));
    group.add(wing);
  }

  return (
    doorAt: doorAt,
    out: f.out,
    slide: (double open) {
      final e = open * open * (3 - 2 * open);
      for (var i = 0; i < leaves.length; i++) {
        final p = leaves[i].position;
        leaves[i].position = vm.Vector3((i > 0 ? 1 : -1) * (hw / 4 + e * (hw / 2 - 0.12)), p.y, p.z);
      }
    },
  );
}

/// A window's frame and its glass, in the hole the shell left for it.
void _viewport(Kit kit, WallFrame f, WallOpening o) {
  final still = kit.still, mats = kit.mats;
  const t = hullThickness;
  const deep = t + 0.24;
  final mid = o.y + o.height / 2;
  final (cx, cz) = f.at(o.u, t / 2);
  // Lapping a little way into the opening, so the frame's faces never lie on the wall's cut edges.
  const lap = 0.05;
  for (final sy in const [-1, 1]) {
    still.add(_m(f.box(o.width + 0.36, 0.18, deep), mats.metalDark, cx, mid + sy * (o.height / 2 + 0.09 - lap), cz));
  }
  for (final su in const [-1, 1]) {
    final (x, z) = f.at(o.u + su * (o.width / 2 + 0.09 - lap), t / 2);
    still.add(_m(f.box(0.18, o.height, deep), mats.metalDark, x, mid, z));
  }
  // A wide one is glazed in two or three lights.
  final lights = o.width > 7 ? 3 : (o.width > 5.2 ? 2 : 1);
  for (var i = 1; i < lights; i++) {
    final (x, z) = f.at(o.u - o.width / 2 + i * o.width / lights, t / 2);
    still.add(_m(f.box(0.1, o.height, 0.2), mats.metalDark, x, mid, z, false));
  }
  // A sill to lean on, inside.
  final (sx, sz) = f.at(o.u, -0.2);
  still.add(_m(f.box(o.width + 0.5, 0.08, 0.4), mats.metal, sx, o.y - 0.04, sz, false));
  kit.group.add(_m(planeXY(o.width, o.height, both: true), mats.glass, cx, mid, cz, false)..rotation = yaw(f.rotY));
}

/// The plan's hull for the shell (the map's palette, filled in).
typedef StationPalette = ({String hull, String deck, String panel, String metal, String glow});

StationPalette stationPalette(MapPlan plan) {
  final c = plan.config ?? const {};
  final custom = c['palette'] is Map ? Map<String, dynamic>.from(c['palette'] as Map) : const <String, dynamic>{};
  String pal(String k, String d) => custom[k] is String ? custom[k] as String : d;
  return (
    hull: pal('hull', '#dfe5ee'),
    deck: pal('deck', '#3d4858'),
    panel: pal('panel', '#aeb8c8'),
    metal: pal('metal', '#56627a'),
    glow: pal('glow', '#35d6ff'),
  );
}
