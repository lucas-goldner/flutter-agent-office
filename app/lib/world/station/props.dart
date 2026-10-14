// The props a station-style map places (see office_shared's maps/station_props.dart): the hull's ribs,
// light pods and the strips in the deck, displays, the holo-table, planters, cargo, the gong and the
// drinks dispenser, each put up by its entry in [stationProps]. (A viewport is cut by the shell:
// shell.dart.) A port of world/station/props.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/station_props.dart' show StationSize;
import 'package:office_shared/maps/types.dart' show PropConfig;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../geo.dart' as g3;
import '../office/geo.dart' show cyl, planeXY;
import '../office/gong.dart' show buildGong;
import '../office/parts.dart' show canvasTexture;
import '../text.dart';
import '../toon.dart';
import 'kit.dart';
import 'textures.dart';

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

/// A group at a prop's spot, turned its way: [y] up, or on whatever's underfoot there (the bridge).
Node _at(Kit kit, PropConfig p, [double? y]) => placed(p.x, y ?? kit.floorAt(p.x, p.z), p.z, p.rotY ?? 0, p.kind);

Geometry _ringFlat(double r, double tube, int radial, int tubular) =>
    g3.torusData(r, tube, radial, tubular).rotateX(math.pi / 2).build();

/// A rib of the hull across the hall at `z`: a column up each long wall, a beam across the ceiling, a
/// brace in each corner.
void _rib(Kit kit, PropConfig p) {
  final b = kit.plan.bounds;
  final h = kit.height;
  final w = b.maxX - b.minX;
  final cx = (b.minX + b.maxX) / 2;
  final m = kit.mats;
  final g = placed(cx, 0, p.z, 0, 'rib');
  g.add(_m(g3.box(w, 0.36, 0.5), m.metal, 0, h - 0.18, 0, false));
  for (final sx in const [-1, 1]) {
    final x = sx * (w / 2 - 0.2);
    g.add(_m(g3.box(0.4, h, 0.5), m.metal, x, h / 2, 0));
    g.add(_m(g3.box(0.5, 0.5, 0.62), m.metalDark, sx * (w / 2 - 0.25), 0.25, 0));
    g.add(
      _m(g3.box(0.3, 2.6, 0.42), m.metalDark, sx * (w / 2 - 1.1), h - 1.1, 0, false)
        ..rotation = g3.euler(0, 0, sx * math.pi / 4),
    );
    g.add(_m(g3.box(0.03, h - 3.2, 0.1), m.accent, sx * (w / 2 - 0.41), (h - 2) / 2, 0, false));
    collide(kit, cx + x, p.z, 0.5, 0.62, 0, 99);
  }
  kit.still.add(g);
}

/// A light pod hanging from the ceiling; a few of them light the deck for real.
void _lamp(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final y = p.y ?? kit.height - 0.9;
  final g = placed(p.x, y, p.z, 0, 'lamp');
  final r = StationSize.lamp * s;
  g.add(_m(cyl(0.04, 0.04, kit.height - y, 6), kit.mats.metalDark, 0, (kit.height - y) / 2, 0, false));
  g.add(_m(cyl(r, r * 1.15, 0.16, 20), kit.mats.metalDark, 0, 0, 0, false));
  g.add(_m(cyl(r * 0.95, r * 0.95, 0.04, 20), kit.mats.lamp, 0, -0.09, 0, false));
  kit.still.add(g);
  if (p.light != true || kit.lights.length >= maxLights) return;
  kit.lights.add(vm.Vector3(p.x, y - 0.5, p.z));
}

/// A strip of light let into the deck, in the floor's color.
void _strip(Kit kit, PropConfig p) {
  final g = _at(kit, p);
  final w = p.width ?? 0.3, l = p.length ?? 6;
  g.add(_m(g3.box(w + 0.14, 0.012, l + 0.14), kit.mats.black, 0, 0.006, 0, false));
  g.add(_m(g3.box(w, 0.014, l), kit.mats.accent, 0, 0.012, 0, false));
  kit.still.add(g);
}

/// A display on a wall: its frame, and telemetry of its own.
void _screen(Kit kit, PropConfig p) {
  final w = p.width ?? 2.4, h = p.height ?? 1.4;
  final g = placed(p.x, p.y ?? 2.6, p.z, p.rotY ?? 0, 'screen');
  g.add(_m(g3.box(w + 0.2, h + 0.2, 0.1), kit.mats.black, 0, 0, 0.05, false));
  const px = 512;
  final py = math.max(64, (px * h / w).round());
  final face = unlitPicture(canvasTexture(px, py, telemetry((p.x * 7 + p.z * 13).round(), px, py, kit.glow)));
  g.add(_m(planeXY(w, h), face, 0, 0, 0.105, false));
  kit.group.add(g);
}

/// A round holo-table: a globe of light turning over it, a little station going round the globe.
void _hologram(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final g = _at(kit, p)..scale = vm.Vector3.all(s);
  final m = kit.mats;
  const r = StationSize.hologram;
  g.add(_m(cyl(r * 0.55, r * 0.7, 0.62, 24), m.metalDark, 0, 0.31, 0));
  g.add(_m(cyl(r, r, 0.14, 32), m.metal, 0, 0.69, 0));
  g.add(_m(cyl(r * 0.72, r * 0.72, 0.02, 32), m.black, 0, 0.77, 0, false));
  g.add(_m(_ringFlat(r * 0.72, 0.03, 6, 40), m.glow, 0, 0.78, 0, false));
  g.add(_m(_ringFlat(r, 0.025, 6, 48), m.accent, 0, 0.69, 0, false));
  // The beam it's thrown up in, and the globe: lines of light round a faint ball. (Lines of light
  // are rings here: the engine draws no wireframes.)
  g.add(_m(cyl(r * 0.78, r * 0.66, 1.9, 28, true), lit(kit.glow, opacity: 0.07), 0, 1.74, 0, false));
  final wire = lit(kit.glow, opacity: 0.75);
  final globe = Node(name: 'globe')
    ..position = vm.Vector3(0, 1.85, 0)
    ..rotation = g3.euler(0, 0, 0.41);
  for (var i = 0; i < 7; i++) {
    globe.add(_m(g3.torus(0.72, 0.006, 4, 40), wire, 0, 0, 0, false)..rotation = g3.euler(0, i * math.pi / 7));
  }
  for (final lat in const [-0.6, -0.3, 0.0, 0.3, 0.6]) {
    globe.add(_m(_ringFlat(0.72 * math.cos(lat), 0.006, 4, 40), wire, 0, 0.72 * math.sin(lat), 0, false));
  }
  globe.add(_m(g3.sphere(0.7, 20, 14), lit(kit.glow, opacity: 0.12), 0, 0, 0, false));
  final spin = Node(name: 'spin')..add(globe);
  g.add(spin);
  // You are here.
  final orbit = Node(name: 'orbit')
    ..position = vm.Vector3(0, 1.85, 0)
    ..rotation = g3.euler(0.5, 0)
    ..add(_m(_ringFlat(1.0, 0.008, 4, 48), lit(kit.glow, opacity: 0.5), 0, 0, 0, false))
    ..add(_m(g3.sphere(0.045, 8, 6), lit('#ffb347'), 1.0, 0, 0, false));
  final round = Node(name: 'round')..add(orbit);
  g.add(round);
  kit.spinners
    ..add(Spinner(spin, 0.25))
    ..add(Spinner(round, -0.9));
  kit.group.add(g);
  final rr = r * s * math.sqrt1_2;
  kit.colliders.add(
    Collider(minX: p.x - rr, maxX: p.x + rr, minZ: p.z - rr, maxZ: p.z + rr, top: g.position.y + 0.78 * s),
  );
}

const List<String> _leaves = ['#3f9b4d', '#57b85a', '#2f7d45', '#7ccf6a'];

/// A hydroponics planter: a trough of something green, with a grow-light's glow along its rim.
void _planter(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final w = p.width ?? StationSize.planter.width;
  final d = StationSize.planter.depth;
  final g = _at(kit, p)..scale = vm.Vector3.all(s);
  g.add(_m(roundedBox(w, 0.5, d, 0.08), kit.mats.white, 0, 0.25, 0));
  g.add(_m(g3.box(w - 0.16, 0.04, d - 0.16), tc('#3a2a20'), 0, 0.5, 0, false));
  g.add(_m(g3.box(w - 0.1, 0.03, 0.03), lit('#ff7ad9'), 0, 0.42, d / 2 + 0.005, false));
  final n = math.max(3, (w / 0.4).round());
  for (var i = 0; i < n; i++) {
    final x = -w / 2 + 0.25 + i * (w - 0.5) / (n - 1);
    final tall = 0.28 + ((i * 37) % 5) * 0.045;
    g.add(_m(g3.cone(0.13, tall, 6), tc(_leaves[i % _leaves.length]), x, 0.52 + tall / 2, i.isOdd ? 0.08 : -0.08));
    g.add(
      _m(g3.sphere(0.11, 8, 6), tc(_leaves[(i + 2) % _leaves.length]), x + 0.14, 0.58, i.isOdd ? -0.1 : 0.1, false),
    );
  }
  kit.still.add(g);
  collide(kit, p.x, p.z, w * s, d * s, p.rotY ?? 0, 0.9 * s);
}

/// Cargo: a crate with banded edges, and a smaller one on top of it.
void _crate(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  const size = StationSize.crate;
  final g = _at(kit, p)..scale = vm.Vector3.all(s);
  void one(double w, double y, String color, double turn, double dx) {
    final c = placed(dx, y, 0, turn, 'crate')..add(_m(g3.box(w, w * 0.8, w), tc(color), 0, w * 0.4, 0));
    for (final sx in const [-1, 1]) {
      for (final sz in const [-1, 1]) {
        c.add(
          _m(
            g3.box(0.09, w * 0.8 + 0.02, 0.09),
            kit.mats.metalDark,
            sx * (w / 2 - 0.03),
            w * 0.4,
            sz * (w / 2 - 0.03),
            false,
          ),
        );
      }
    }
    for (final sy in [0.05, w * 0.8 - 0.05]) {
      c.add(_m(g3.box(w + 0.03, 0.09, w + 0.03), kit.mats.metalDark, 0, sy, 0, false));
    }
    c.add(_m(g3.box(w * 0.4, w * 0.22, 0.02), kit.mats.white, 0, w * 0.45, w / 2 + 0.01, false));
    g.add(c);
  }

  one(size * 0.92, 0, '#d0812f', 0, 0);
  one(size * 0.55, size * 0.92 * 0.8, '#5c7fa3', 0.5, 0.12);
  kit.still.add(g);
  collide(kit, p.x, p.z, size * s, size * s, p.rotY ?? 0, 99);
}

/// A drinks dispenser against a wall: a cup from it perks you up, like the office's coffee.
void _dispenser(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final w = StationSize.dispenser.width, d = StationSize.dispenser.depth;
  final g = _at(kit, p)..scale = vm.Vector3.all(s);
  final m = kit.mats;
  g.add(_m(roundedBox(w, 2, d, 0.08), m.metalDark, 0, 1.0, 0));
  g.add(_m(g3.box(w - 0.24, 0.62, 0.04), m.black, 0, 1.45, d / 2 + 0.01, false));
  g.add(_m(g3.box(w - 0.4, 0.07, 0.02), m.glow, 0, 1.6, d / 2 + 0.035, false));
  g.add(_m(g3.box(w - 0.6, 0.07, 0.02), m.glow, -0.1, 1.45, d / 2 + 0.035, false));
  // The alcove a cup's filled in, a spout over it, and a cup waiting.
  g.add(_m(g3.box(w - 0.3, 0.46, 0.06), m.black, 0, 0.86, d / 2 - 0.02, false));
  g.add(_m(cyl(0.03, 0.03, 0.12, 8), m.metal, 0, 1.03, d / 2 + 0.06, false));
  g.add(_m(g3.box(w - 0.3, 0.05, 0.24), m.metal, 0, 0.64, d / 2 + 0.1, false));
  g.add(_m(cyl(0.06, 0.05, 0.14, 12), m.white, 0, 0.74, d / 2 + 0.1, false));
  g.add(
    textPlane('☕ Hot drinks', const TextOpts(bg: '#0f1a26', color: '#cfeeff', border: '#3a5a78', size: 48))
      ..position = vm.Vector3(0, 2.25, d / 2 - 0.1)
      ..scale = vm.Vector3.all(0.6),
  );
  kit.group.add(g);
  final r = p.rotY ?? 0;
  collide(kit, p.x, p.z, w * s, d * s, r, 99);
  final y = g.position.y;
  final it = Interactable(
    kind: InteractKind.coffee,
    label: '☕ Drinks dispenser',
    x: p.x + math.sin(r) * 1.1,
    y: y == 0 ? null : y,
    z: p.z + math.cos(r) * 1.1,
    radius: 1.5,
  );
  tagInteract(g, it);
  kit.interactables.add(it);
}

/// A console table with nothing to sit at.
void _plainTable(Kit kit, PropConfig p) {
  final w = p.width ?? 1.4, l = p.length ?? 3;
  final g = _at(kit, p);
  g.add(_m(roundedBox(w, 0.08, l, 0.06), kit.mats.white, 0, tableTop - 0.04, 0));
  for (final sz in const [-1, 1]) {
    g.add(
      _m(
        g3.box(math.max(0.3, w - 0.5), tableTop - 0.08, 0.24),
        kit.mats.metalDark,
        0,
        (tableTop - 0.08) / 2,
        sz * (l / 2 - 0.4),
      ),
    );
  }
  kit.still.add(g);
  collide(kit, p.x, p.z, w, l, p.rotY ?? 0, g.position.y + tableTop);
}

void _gong(Kit kit, PropConfig p) {
  final gong = buildGong((x: p.x, y: kit.floorAt(p.x, p.z), z: p.z, rotY: p.rotY ?? 0));
  kit.group.add(gong.group);
  kit.colliders.addAll(gong.colliders);
  kit.interactables.add(gong.interactable);
  kit.gong = gong;
}

/// Each kind of prop, put up (every kind there is has one: see stationPropKinds).
final Map<String, void Function(Kit kit, PropConfig p)> stationProps = {
  'rib': _rib,
  // Cut through its wall by the shell, frame and glass and all.
  'viewport': (_, _) {},
  'lamp': _lamp,
  'strip': _strip,
  'screen': _screen,
  'hologram': _hologram,
  'planter': _planter,
  'crate': _crate,
  'gong': _gong,
  'dispenser': _dispenser,
  'table': _plainTable,
};
