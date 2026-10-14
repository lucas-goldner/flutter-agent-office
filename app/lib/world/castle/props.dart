// The props a castle-style map places (see office_shared's maps/props.dart): pillars and the arcade
// between them, torches, braziers and chandeliers, banners, windows, statues, armor, the hearth, the ale
// casks and the rest, each put up by its entry in [castleProps]. A port of world/castle/props.ts.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/props.dart' show PropSize;
import 'package:office_shared/maps/types.dart' show PropConfig;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../geo.dart' as g3;
import '../office/geo.dart' show cone, cyl, extrudeShape, Shape2, sphere, yaw;
import '../office/gong.dart' show buildGong;
import '../office/parts.dart' show canvasTexture;
import '../office/geo.dart' show setToonTexture;
import '../text.dart';
import '../toon.dart';
import 'fire.dart';
import 'kit.dart';
import 'shapes.dart';
import 'textures.dart';

/// A group at a prop's spot, turned its way: [y] up, or on whatever's underfoot there (the dais).
Node placed(PropConfig p, [double? y]) => Node(name: p.kind)
  ..position = vm.Vector3(p.x, y ?? p.y ?? 0, p.z)
  ..rotation = yaw(p.rotY ?? 0);

/// (lx, ly, lz) in a group at (x, y, z) turned [rotY], in the castle's space.
vm.Vector3 _out(Node g, double rotY, double lx, double ly, double lz) {
  final c = math.cos(rotY), s = math.sin(rotY);
  final at = g.position;
  return vm.Vector3(at.x + lx * c + lz * s, at.y + ly, at.z - lx * s + lz * c);
}

Node _m(Geometry geo, Material mat, [double x = 0, double y = 0, double z = 0, bool shadow = true]) =>
    mesh(geo, mat, x, y, z, shadow);

void _pillar(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final w = PropSize.pillar * s;
  final h = kit.height;
  final g = placed(p, 0);
  final m = kit.mats;
  g.add(_m(g3.box(w, 0.7, w), m.stoneDark, 0, 0.35, 0));
  g.add(_m(g3.box(w * 0.86, 0.18, w * 0.86), m.stoneDark, 0, 0.79, 0));
  // Four shafts clustered round a core, the way a Gothic pier is.
  g.add(_m(g3.box(w * 0.62, h - 1.9, w * 0.62), m.stone, 0, 0.7 + (h - 1.9) / 2, 0));
  for (final (dx, dz) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
    g.add(_m(cyl(w * 0.17, w * 0.17, h - 1.9, 10), m.stone, dx * w * 0.31, 0.7 + (h - 1.9) / 2, dz * w * 0.31));
  }
  g.add(_m(g3.box(w * 1.05, 0.5, w * 1.05), m.stoneDark, 0, h - 1.0, 0));
  g.add(_m(g3.box(w * 0.8, 0.5, w * 0.8), m.stoneDark, 0, h - 0.5, 0));
  kit.still.add(g);
  collide(kit, p.x, p.z, w, w, p.rotY ?? 0, 99);
}

/// Pointed arches between neighbouring pillars along each side (the arcade).
void arcade(Kit kit, List<PropConfig> pillars) {
  final rows = <int, List<PropConfig>>{};
  for (final p in pillars) {
    (rows[(p.x * 10).round()] ??= []).add(p);
  }
  final h = kit.height;
  for (final row in rows.values) {
    row.sort((a, b) => a.z.compareTo(b.z));
    for (var i = 1; i < row.length; i++) {
      final a = row[i - 1], b = row[i];
      final gap = b.z - a.z;
      final w = PropSize.pillar * math.max(a.scale ?? 1, b.scale ?? 1);
      if (gap > 9 || gap < w + 1) continue;
      final span = gap - w * 0.9;
      final rise = archRise(span, span * 0.8, 0.45);
      final spring = math.max(2.5, h - 1.25 - rise);
      final arch = _m(archBand(span, 0.45, w * 0.55), kit.mats.stone)
        ..position = vm.Vector3(a.x, spring, (a.z + b.z) / 2)
        ..rotation = yaw(math.pi / 2);
      kit.still.add(arch);
      // The wall over the arch, up to the beam the roof trusses sit on.
      kit.still.add(_m(g3.box(w * 0.5, 0.5, gap), kit.mats.stoneDark, a.x, h - 0.25, (a.z + b.z) / 2));
    }
  }
}

void torch(Kit kit, PropConfig p) {
  final y = p.y ?? 2.7;
  final g = placed(p, y);
  final m = kit.mats;
  // An iron bracket on the wall, the torch leaning out of its cup.
  g.add(_m(g3.box(0.22, 0.34, 0.06), m.iron, 0, 0, 0.03));
  g.add(_m(g3.box(0.05, 0.05, 0.36), m.iron, 0, -0.08, 0.2));
  g.add(_m(cyl(0.1, 0.06, 0.16, 8), m.iron, 0, 0.02, 0.36));
  g.add(_m(cyl(0.045, 0.035, 0.62, 6), m.woodDark, 0, 0.26, 0.4)..rotation = g3.euler(0.25, 0));
  kit.group.add(g);
  flame(kit, g, 0, 0.56, 0.48, 0.34);
  if (p.light == true) {
    final at = _out(g, p.rotY ?? 0, 0, 0.8, 0.7);
    fireLight(kit, at.x, at.y, at.z, 16);
  }
}

void _brazier(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final g = placed(p, kit.floorAt(p.x, p.z))..scale = vm.Vector3.all(s);
  final iron = kit.mats.iron;
  for (var i = 0; i < 3; i++) {
    final a = i / 3 * math.pi * 2;
    g.add(
      _m(cyl(0.035, 0.05, 1.05, 6), iron, math.sin(a) * 0.26, 0.5, math.cos(a) * 0.26)
        ..rotation = g3.euler(math.cos(a) * 0.22, 0, -math.sin(a) * 0.22),
    );
  }
  g.add(_m(g3.lathe(const [(0.05, 0), (0.38, 0.08), (0.55, 0.3), (0.58, 0.34)], 16), iron, 0, 0.95, 0));
  g.add(_m(g3.torusData(0.57, 0.035, 6, 20).rotateX(math.pi / 2).build(), kit.mats.gold, 0, 1.28, 0, false));
  g.add(_m(cyl(0.46, 0.46, 0.08, 14), tc('#3a1f14', emissive: '#7a2a0a'), 0, 1.2, 0, false));
  kit.group.add(g);
  flame(kit, g, 0, 1.2, 0, 0.62);
  flame(kit, g, 0.2, 1.2, 0.12, 0.38);
  flame(kit, g, -0.18, 1.2, -0.1, 0.42);
  if (p.light == true) fireLight(kit, p.x, g.position.y + 2.3 * s, p.z, 30);
  kit.colliders.add(
    Collider(
      minX: p.x - 0.5 * s,
      maxX: p.x + 0.5 * s,
      minZ: p.z - 0.5 * s,
      maxZ: p.z + 0.5 * s,
      top: g.position.y + 1.3 * s,
      fence: true,
    ),
  );
}

void _chandelier(Kit kit, PropConfig p) {
  final y = p.y ?? kit.height - 4;
  final g = placed(p, y);
  final m = kit.mats;
  final r = 1.35 * (p.scale ?? 1);
  g.add(_m(g3.torusData(r, 0.06, 6, 28).rotateX(math.pi / 2).build(), m.iron));
  g.add(_m(g3.torusData(r * 0.45, 0.04, 6, 20).rotateX(math.pi / 2).build(), m.iron, 0, -0.35, 0));
  // Three chains up to a ring, and one from there up to the roof.
  final up = kit.height + 1 - y;
  final hub = vm.Vector3(0, 1.4, 0);
  for (var i = 0; i < 3; i++) {
    final a = i / 3 * math.pi * 2;
    g.add(rod(vm.Vector3(math.sin(a) * r, 0, math.cos(a) * r), hub, 0.018, m.iron));
  }
  g.add(rod(hub, vm.Vector3(0, up, 0), 0.03, m.iron));
  kit.group.add(g);
  const n = 10;
  for (var i = 0; i < n; i++) {
    final a = i / n * math.pi * 2;
    final x = math.sin(a) * r, z = math.cos(a) * r;
    g.add(_m(cyl(0.05, 0.05, 0.3, 6), m.candle, x, 0.18, z, false));
    flame(kit, g, x, 0.34, z, 0.11);
  }
}

void _banner(Kit kit, PropConfig p, String color) {
  final w = p.width ?? 1.2;
  final h = p.height ?? 4;
  final g = placed(p, p.y ?? kit.height - 2);
  final great = w >= 3;
  const pw = 256;
  final ph = math.min(2048, math.max(64, (256 * h / w).round()));
  final cloth = Toon.create(const Color(0xFFFFFFFF))..doubleSided = true;
  canvasTexture(
    pw,
    ph,
    (c) => paintBanner(c, pw.toDouble(), ph.toDouble(), color),
  ).then((t) => setToonTexture(cloth, t));
  kit.banners.add(Banner(cloth, pw, ph, great));
  // Cut to a swallowtail at the foot.
  final outline = [
    vm.Vector2(-w / 2, 0),
    vm.Vector2(w / 2, 0),
    vm.Vector2(w / 2, -h),
    vm.Vector2(0, -h + w * 0.45),
    vm.Vector2(-w / 2, -h),
  ];
  g.add(_m(flatShape(outline, uvOf: (q) => ((q.x + w / 2) / w, 1 + q.y / h), both: true), cloth, 0, 0, 0.08, false));
  // The pole it hangs from, with a gold knob either end.
  g.add(
    _m(
      g3.cylinderData(0.045, 0.045, w + 0.4, 8).transform(vm.Matrix4.rotationZ(math.pi / 2)).build(),
      kit.mats.woodDark,
      0,
      0.05,
      0.1,
      false,
    ),
  );
  for (final sx in const [-1, 1]) {
    g.add(_m(sphere(0.08, 8, 6), kit.mats.gold, sx * (w / 2 + 0.22), 0.05, 0.1, false));
  }
  kit.group.add(g);
}

void _glassWindow(Kit kit, PropConfig p, int seed) {
  final w = p.width ?? 2.2;
  final h = p.height ?? 5;
  final g = placed(p, p.y ?? 6);
  // The picture's as tall as the window is for its width, within reason.
  final th = math.min(1024, math.max(64, (256 * h / w).round()));
  final mat = UnlitMaterial();
  canvasTexture(256, th, stainedGlass(seed, 256, th.toDouble())).then((t) => mat.baseColorTexture = t);
  kit.glass.add(mat);
  g.add(_m(archPane(w, h), mat, 0, 0, 0.02, false));
  // A stone frame round it: the jambs, the sill, and the arch over it.
  final r = w * 0.85;
  final rise = archRise(w, r);
  final dark = kit.mats.stoneDark;
  for (final sx in const [-1, 1]) {
    g.add(_m(g3.box(0.28, h - rise, 0.3), dark, sx * (w / 2 + 0.14), (h - rise) / 2, 0.05));
  }
  g.add(_m(g3.box(w + 0.7, 0.25, 0.45), dark, 0, -0.12, 0.12));
  g.add(_m(archBand(w, 0.28, 0.3, r), dark, 0, h - rise, 0.05));
  // A mullion down the middle.
  g.add(_m(g3.box(0.09, h - rise * 0.6, 0.12), dark, 0, (h - rise * 0.6) / 2, 0.06, false));
  // Not merged with the stonework: the glass keeps its picture's coordinates that way.
  kit.group.add(g);
}

void _rose(Kit kit, PropConfig p) {
  final d = p.width ?? 4.5;
  final g = placed(p, p.y ?? kit.height - 3);
  final mat = UnlitMaterial();
  canvasTexture(512, 512, roseGlass).then((t) => mat.baseColorTexture = t);
  kit.glass.add(mat);
  final disc = [
    for (var i = 0; i < 40; i++)
      vm.Vector2(math.cos(i / 40 * math.pi * 2) * d / 2, math.sin(i / 40 * math.pi * 2) * d / 2),
  ];
  g.add(_m(flatShape(disc), mat, 0, 0, 0.03, false));
  g.add(_m(g3.torus(d / 2 + 0.1, 0.22, 8, 40), kit.mats.stoneDark, 0, 0, 0.08));
  for (var i = 0; i < 8; i++) {
    g.add(
      _m(g3.box(0.1, d - 0.2, 0.1), kit.mats.stoneDark, 0, 0, 0.07, false)..rotation = g3.euler(0, 0, i / 8 * math.pi),
    );
  }
  kit.group.add(g);
}

void _carpet(Kit kit, PropConfig p) {
  final w = p.width ?? 3;
  final l = p.length ?? 10;
  final g = placed(p, kit.floorAt(p.x, p.z));
  g.add(_m(g3.box(w, 0.025, l), kit.mats.carpet, 0, 0.013, 0, false));
  for (final sx in const [-1, 1]) {
    g.add(_m(g3.box(0.14, 0.03, l), kit.mats.gold, sx * (w / 2 - 0.2), 0.016, 0, false));
  }
  kit.still.add(g);
}

/// A knight in pale stone on a plinth, leaning on a sword.
void _statue(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final g = placed(p, kit.floorAt(p.x, p.z))..scale = vm.Vector3.all(s);
  final pale = tc('#c9c2b4');
  final plinth = kit.mats.stoneDark;
  g.add(_m(g3.box(1.3, 1.0, 1.3), plinth, 0, 0.5, 0));
  g.add(_m(g3.box(1.45, 0.15, 1.45), plinth, 0, 1.07, 0));
  for (final sx in const [-1, 1]) {
    g.add(_m(cyl(0.13, 0.15, 0.95, 8), pale, sx * 0.16, 1.62, 0));
  }
  g.add(_m(cyl(0.34, 0.26, 0.95, 10), pale, 0, 2.55, 0));
  for (final sx in const [-1, 1]) {
    g.add(_m(sphere(0.17, 10, 8), pale, sx * 0.36, 2.95, 0));
  }
  g.add(_m(cyl(0.2, 0.22, 0.4, 12), pale, 0, 3.28, 0));
  g.add(_m(g3.sphere(0.21, 12, 8, 0, math.pi * 2, 0, math.pi / 2), pale, 0, 3.45, 0));
  g.add(_m(g3.box(0.28, 0.035, 0.05), tc('#6e675c'), 0, 3.3, 0.2, false));
  // Both hands on the pommel of a sword stood point down in front of it.
  g.add(_m(g3.box(0.1, 1.15, 0.03), pale, 0, 1.75, 0.36));
  g.add(_m(g3.box(0.5, 0.07, 0.07), pale, 0, 2.35, 0.36));
  g.add(_m(sphere(0.08, 8, 6), pale, 0, 2.55, 0.36));
  for (final sx in const [-1, 1]) {
    g.add(_m(cyl(0.08, 0.08, 0.6, 6), pale, sx * 0.22, 2.55, 0.2)..rotation = g3.euler(0.7, 0, -sx * 0.5));
  }
  kit.still.add(g);
  collide(kit, p.x, p.z, PropSize.statue * s, PropSize.statue * s, p.rotY ?? 0, 99);
}

void _armor(Kit kit, PropConfig p) {
  final g = placed(p, kit.floorAt(p.x, p.z));
  final m = kit.mats;
  g.add(_m(cyl(0.3, 0.34, 0.08, 12), m.woodDark, 0, 0.04, 0));
  for (final sx in const [-1, 1]) {
    g.add(_m(cyl(0.09, 0.11, 0.9, 8), m.steel, sx * 0.13, 0.53, 0));
  }
  g.add(_m(cyl(0.3, 0.24, 0.8, 10), m.steel, 0, 1.38, 0));
  g.add(_m(cyl(0.27, 0.27, 0.12, 10), m.iron, 0, 1.0, 0));
  for (final sx in const [-1, 1]) {
    g.add(_m(sphere(0.17, 10, 8), m.steel, sx * 0.36, 1.72, 0));
    g.add(_m(cyl(0.07, 0.07, 0.62, 6), m.steel, sx * 0.4, 1.35, 0));
  }
  g.add(_m(cyl(0.2, 0.21, 0.36, 12), m.steel, 0, 2.02, 0));
  g.add(_m(g3.sphere(0.2, 12, 8, 0, math.pi * 2, 0, math.pi / 2), m.steel, 0, 2.18, 0));
  g.add(_m(g3.box(0.26, 0.035, 0.05), m.iron, 0, 2.06, 0.19, false));
  g.add(_m(cone(0.05, 0.3, 6), tc('#9b1c1c'), 0, 2.45, 0, false));
  // A halberd at its side.
  g.add(_m(cyl(0.03, 0.03, 2.7, 6), m.woodDark, 0.52, 1.35, 0.1));
  g.add(_m(g3.box(0.05, 0.4, 0.28), m.steel, 0.52, 2.55, 0.2));
  kit.still.add(g);
  const r = PropSize.armor;
  kit.colliders.add(Collider(minX: p.x - r, maxX: p.x + r, minZ: p.z - r, maxZ: p.z + r, top: 99));
}

void _shield(Kit kit, PropConfig p) {
  final g = placed(p, p.y ?? 3.5);
  final s = Shape2(12)
    ..moveTo(-0.5, 0.5)
    ..lineTo(0.5, 0.5)
    ..quadraticCurveTo(0.5, -0.3, 0, -0.75)
    ..quadraticCurveTo(-0.5, -0.3, -0.5, 0.5);
  final field = toonUnique(hex('#9b1c1c'));
  kit.shields.add(field);
  g.add(_m(extrudeShape(s, 0.06), field, 0, 0, 0.12));
  g.add(_m(g3.box(0.16, 1.05, 0.02), kit.mats.gold, 0, -0.1, 0.19, false));
  g.add(_m(g3.box(0.8, 0.16, 0.02), kit.mats.gold, 0, 0.15, 0.19, false));
  // Two swords crossed behind it.
  for (final sx in const [-1, 1]) {
    final sword = Node(name: 'sword')
      ..add(_m(g3.box(0.08, 1.6, 0.02), kit.mats.steel, 0, 0.1, 0, false))
      ..add(_m(g3.box(0.34, 0.06, 0.05), kit.mats.gold, 0, -0.7, 0, false))
      ..add(_m(cyl(0.025, 0.025, 0.25, 6), kit.mats.woodDark, 0, -0.85, 0, false))
      ..position = vm.Vector3(0, -0.1, 0.06)
      ..rotation = g3.euler(0, 0, sx * 0.75);
    g.add(sword);
  }
  kit.group.add(g);
}

void _hearth(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final w = (p.width ?? PropSize.hearth.width) * s;
  final d = PropSize.hearth.depth * s;
  final at = placed(p, 0);
  // Built from its back (against the wall) out; its spot is its middle.
  final g = Node(name: 'hearth')..position = vm.Vector3(0, 0, -d / 2);
  at.add(g);
  final m = kit.mats;
  g.add(_m(g3.box(w, 2.6, 0.25), tc('#2a211c'), 0, 1.3, 0.12));
  for (final sx in const [-1, 1]) {
    g.add(_m(g3.box(0.5, 2.3, d), m.stoneDark, sx * (w / 2 - 0.25), 1.15, d / 2));
  }
  g.add(_m(g3.box(w + 0.3, 0.35, d + 0.2), m.stoneDark, 0, 2.45, d / 2 + 0.05));
  g.add(_m(g3.box(w + 0.1, 0.15, d + 0.1), m.woodDark, 0, 2.7, d / 2 + 0.05));
  // The hood, tapering up to the roof.
  g.add(
    _m(cyl(w * 0.32, w * 0.55, kit.height - 2.8, 4), m.stone, 0, 2.8 + (kit.height - 2.8) / 2, d * 0.3)
      ..rotation = yaw(math.pi / 4)
      ..scale = vm.Vector3(1, 1, 0.45),
  );
  g.add(_m(g3.box(w - 0.8, 0.1, d - 0.2), tc('#3a1f14', emissive: '#5a1a05'), 0, 0.05, d / 2, false));
  for (final (x, rz) in const [(-0.3, 0.2), (0.25, -0.25), (0.0, 0.0)]) {
    g.add(_m(cyl(0.1, 0.1, 1.1, 8), m.woodDark, x, 0.18, d / 2)..rotation = g3.euler(0, rz, math.pi / 2));
  }
  kit.group.add(at);
  flame(kit, g, 0, 0.2, d / 2, 0.75);
  flame(kit, g, -0.35, 0.2, d / 2 + 0.1, 0.5);
  flame(kit, g, 0.35, 0.2, d / 2 - 0.05, 0.55);
  if (p.light == true) {
    final lit = _out(at, p.rotY ?? 0, 0, 1.1, d / 2 + 0.6);
    fireLight(kit, lit.x, lit.y, lit.z, 34);
  }
  collide(kit, p.x, p.z, w, d, p.rotY ?? 0, 99);
}

Interactable _cask(Kit kit, PropConfig p) {
  final s = p.scale ?? 1;
  final g = placed(p, kit.floorAt(p.x, p.z))..scale = vm.Vector3.all(s);
  final m = kit.mats;
  g.add(_m(g3.box(1.7, 0.12, 0.9), m.woodDark, 0, 0.3, 0));
  for (final sx in const [-0.6, 0.6]) {
    g.add(_m(g3.box(0.12, 0.3, 0.9), m.woodDark, sx, 0.15, 0));
  }
  for (final (x, y, r) in const [(-0.42, 0.72, 0.36), (0.42, 0.72, 0.36), (0.0, 1.33, 0.32)]) {
    final barrel = Node(name: 'barrel')..position = vm.Vector3(x, y, 0);
    barrel.add(_m(g3.cylinderData(r, r, 0.85, 14).rotateX(math.pi / 2).build(), m.wood));
    for (final bz in const [-0.3, 0.0, 0.3]) {
      barrel.add(_m(g3.torus(r + 0.01, 0.022, 5, 18), m.iron, 0, 0, bz, false));
    }
    barrel.add(
      _m(g3.cylinderData(0.035, 0.035, 0.12, 6).rotateX(math.pi / 2).build(), m.iron, 0, -r * 0.4, 0.46, false),
    );
    g.add(barrel);
  }
  // Tankards on the rack.
  for (final x in const [-0.72, 0.72]) {
    g.add(_m(cyl(0.07, 0.08, 0.18, 10), tc('#8d939c'), x, 1.0, 0.25, false));
  }
  g.add(
    textPlane('🍺 Ale', const TextOpts(bg: '#efe3c2', size: 48))
      ..position = vm.Vector3(0, 1.85, 0.2)
      ..scale = vm.Vector3.all(0.55),
  );
  kit.group.add(g);
  final r = p.rotY ?? 0;
  collide(kit, p.x, p.z, PropSize.cask.width * s, PropSize.cask.depth * s, r, g.position.y + 1.6 * s);
  final it = Interactable(
    kind: InteractKind.coffee,
    label: '🍺 Ale casks',
    x: p.x + math.sin(r) * 1.1,
    y: g.position.y == 0 ? null : g.position.y,
    z: p.z + math.cos(r) * 1.1,
    radius: 1.5,
  );
  tagInteract(g, it);
  return it;
}

void _plainTable(Kit kit, PropConfig p) {
  final w = p.width ?? 1.4;
  final l = p.length ?? 3;
  final g = placed(p, kit.floorAt(p.x, p.z));
  g.add(_m(roundedBox(w, 0.1, l, 0.05), kit.mats.wood, 0, tableTop - 0.05, 0));
  for (final sz in const [-1, 1]) {
    g.add(_m(g3.box(w - 0.2, tableTop - 0.1, 0.12), kit.mats.woodDark, 0, (tableTop - 0.1) / 2, sz * (l / 2 - 0.3)));
  }
  kit.still.add(g);
  collide(kit, p.x, p.z, w, l, p.rotY ?? 0, g.position.y + tableTop);
}

void _candles(Kit kit, PropConfig p) {
  final g = placed(p, kit.floorAt(p.x, p.z));
  final m = kit.mats;
  g.add(_m(cyl(0.22, 0.26, 0.06, 10), m.iron, 0, 0.03, 0));
  g.add(_m(cyl(0.03, 0.03, 1.6, 6), m.iron, 0, 0.83, 0));
  g.add(_m(g3.box(0.7, 0.04, 0.04), m.iron, 0, 1.6, 0, false));
  kit.group.add(g);
  for (final x in const [-0.33, 0.0, 0.33]) {
    final y = x != 0 ? 1.62 : 1.66;
    g.add(_m(cyl(0.04, 0.04, 0.26, 6), m.candle, x, y + 0.13, 0, false));
    flame(kit, g, x, y + 0.27, 0, 0.1);
  }
  kit.colliders.add(Collider(minX: p.x - 0.25, maxX: p.x + 0.25, minZ: p.z - 0.25, maxZ: p.z + 0.25, top: 99));
}

void _gong(Kit kit, PropConfig p) {
  final gong = buildGong((x: p.x, y: kit.floorAt(p.x, p.z), z: p.z, rotY: p.rotY ?? 0));
  kit.group.add(gong.group);
  kit.colliders.addAll(gong.colliders);
  kit.interactables.add(gong.interactable);
  kit.gong = gong;
}

/// Each kind of prop, put up (every kind there is has one: see propKinds).
final Map<String, void Function(Kit kit, PropConfig p)> castleProps = {
  'pillar': _pillar,
  'torch': torch,
  'brazier': _brazier,
  'chandelier': _chandelier,
  'banner': (kit, p) => _banner(kit, p, '#9b1c1c'),
  'window': (kit, p) => _glassWindow(kit, p, kit.windows++),
  'rose': _rose,
  'carpet': _carpet,
  'statue': _statue,
  'armor': _armor,
  'shield': _shield,
  'hearth': _hearth,
  'gong': _gong,
  'cask': (kit, p) => kit.interactables.add(_cask(kit, p)),
  'table': _plainTable,
  'candles': _candles,
};
