// What every part of the castle is built with: its sizes, the Kit the builder hands each part, the
// materials in the map's colors, how a part says what's in the way, and the few helpers three.js
// gave the castle for free (a tiled box of stone, a flat shape with a picture on it, a rod).
// A port of world/castle/kit.ts and the helpers in shapes.ts.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter/painting.dart' show HSLColor;
import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart' show DeskDef;
import 'package:office_shared/maps/props.dart' show boxFootprint;
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../costumes.dart' show triangulate;
import '../office/geo.dart' show setToonTexture;
import '../office/office.dart' show DeskView, Gong;
import '../toon.dart';

/// The most torches and braziers that light the room for real (the rest just glow).
const int maxLights = 8;
const double tableTop = 0.78;
const double benchTop = 0.45;
const ({double width, double height}) doorway = (width: 5, height: 6.6);

/// The hall's outside walls are this thick.
const double castleWall = 0.6;

/// The materials a castle is built from, in the map's colours.
class Mats {
  Mats({
    required this.stone,
    required this.stoneDark,
    required this.wood,
    required this.woodDark,
    required this.iron,
    required this.steel,
    required this.gold,
    required this.carpet,
    required this.velvet,
    required this.parchment,
    required this.candle,
  });

  final Material stone, stoneDark, wood, woodDark, iron, steel, gold, carpet, velvet, parchment, candle;
}

/// A flame to flicker (see the castle's update): its cones, its glow, how big and where in its flicker.
class Flame {
  Flame(this.mesh, this.glow, this.size, this.phase);
  final Node mesh;
  final Node glow;
  final double size;
  final double phase;
}

/// A real light among the fires: where (in the castle's space), how bright, and its flicker's phase.
class FireLight {
  FireLight(this.at, this.base, this.phase) : home = at.clone();

  /// Where it burns now (the castle lends the hall's to the dungeon's torches while you're down there).
  vm.Vector3 at;

  /// Where it burns in the hall.
  final vm.Vector3 home;
  final double base;
  final double phase;
  double intensity = 0;
}

/// The banners, to repaint in a floor's colors; the great one with the project's name on it.
class Banner {
  Banner(this.material, this.w, this.h, this.great);
  final Material material;
  final int w, h;
  final bool great;
}

/// What the builder hands the props: where to put meshes, what's in the way, and the fires to animate.
class Kit {
  Kit({required this.group, required this.mats, required this.height});

  final Node group;

  /// Merged into a few draw calls at the end: whatever never moves.
  final Node still = Node(name: 'castle-still');
  final List<Collider> colliders = [];
  final List<Interactable> interactables = [];
  final List<Flame> flames = [];
  final List<FireLight> lights = [];
  final Mats mats;
  final double height;

  /// Every seat by id, as it's built.
  final Map<String, DeskView> desks = {};

  /// What paints itself over later: the stained glass (dimmer at night), the banners and the shields
  /// (in a floor's colors).
  final List<UnlitMaterial> glass = [];
  final List<Banner> banners = [];
  final List<Material> shields = [];

  /// How many windows so far, so each one's glass is its own pattern.
  int windows = 1;
  Gong? gong;

  /// The top of whatever the floor is at (x, z): the dais, or the floor.
  double floorAt(double x, double z) {
    var top = 0.0;
    for (final c in colliders) {
      if (c.top < 50 && !c.fence && c.top > top && x > c.minX && x < c.maxX && z > c.minZ && z < c.maxZ) top = c.top;
    }
    return top;
  }
}

/// The colors of the stone and the rest, as the map's palette has them.
Mats castleMaterials({required String stone, required String wood, required String trim, required String carpet}) =>
    Mats(
      stone: tc(stone),
      stoneDark: tc(shade(stone, -0.1)),
      wood: tc(wood),
      woodDark: tc(shade(wood, -0.1)),
      iron: tc('#2f3036'),
      steel: tc('#a3a9b2'),
      gold: tc(trim),
      carpet: tc(carpet),
      velvet: tc('#6d1414'),
      parchment: tc('#efe3c2'),
      candle: tc('#f3ead2'),
    );

/// The cached toon material in colour '#rrggbb'.
Material tc(String h, {String? emissive}) => toon(hex(h), emissive: emissive == null ? null : hex(emissive));

/// Something [w] by [d] at (x, z), turned [rotY], standing [top] high: in the way (see Collider).
void collide(Kit kit, double x, double z, double w, double d, double rotY, double top, {bool fence = false}) {
  final (minX, maxX, minZ, maxZ) = boxFootprint(x, z, w, d, rotY);
  kit.colliders.add(Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, top: top, fence: fence));
}

/// [color] lighter (+[k]) or darker (−) by HSL lightness, in linear light as three.js's offsetHSL works.
String shade(String color, double k) {
  final c = hex(color);
  double lin(double v) => v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  double srgb(double v) => v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
  final l = Color.from(alpha: 1, red: lin(c.r), green: lin(c.g), blue: lin(c.b));
  final hsl = HSLColor.fromColor(l);
  final out = hsl.withLightness((hsl.lightness + k).clamp(0.0, 1.0)).toColor();
  int byte(double v) => (srgb(v.clamp(0.0, 1.0)) * 255).round().clamp(0, 255);
  return '#${[byte(out.r), byte(out.g), byte(out.b)].map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
}

/// A little randomness that's the same every time, so every browser sees the same stones (its own LCG,
/// not the shared rng, or every stone moves).
double Function() seeded(int seed) {
  var s = seed & 0xffffffff;
  return () {
    s = (s * 1664525 + 1013904223) & 0xffffffff;
    return s / 4294967296;
  };
}

/// A toon material with a picture on it (stone, flagstones, boards): white until the picture's painted.
PreprocessedMaterial texToon(Future<Texture2D> tex) {
  final m = Toon.create(const Color(0xFFFFFFFF));
  tex.then((t) => setToonTexture(m, t)).catchError((Object _) {});
  return m;
}

Float32List _f32(List<double> v) => Float32List.fromList(v);

/// A flat outline in XY facing +z (three's ShapeGeometry), with UVs from [uvOf] (by default over its
/// bounding box). [both]: a back face too, for cloth seen from behind.
Geometry flatShape(List<vm.Vector2> outline, {(double, double) Function(vm.Vector2 p)? uvOf, bool both = false}) {
  final pts = [...outline];
  if (pts.length > 1 && (pts.first - pts.last).length < 1e-9) pts.removeLast();
  var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
  for (final q in pts) {
    minX = math.min(minX, q.x);
    maxX = math.max(maxX, q.x);
    minY = math.min(minY, q.y);
    maxY = math.max(maxY, q.y);
  }
  final uvAt = uvOf ?? (q) => ((q.x - minX) / (maxX - minX), (q.y - minY) / (maxY - minY));
  final p = <double>[], n = <double>[], uv = <double>[];
  void vert(vm.Vector2 q, double nz) {
    p.addAll([q.x, q.y, nz * 0.0005]);
    n.addAll([0, 0, nz]);
    final (u, v) = uvAt(q);
    // three's v runs up the picture; the engine's runs down it.
    uv.addAll([u, 1 - v]);
  }

  // Counter-clockwise from the front, whichever way the outline was drawn.
  var area = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    area += a.x * b.y - b.x * a.y;
  }
  for (final (a, b, c) in triangulate(pts)) {
    final tri = area >= 0 ? [a, b, c] : [a, c, b];
    for (final i in tri) {
      vert(pts[i], 1);
    }
    if (both) {
      for (final i in tri.reversed) {
        vert(pts[i], -1);
      }
    }
  }
  return MeshGeometry.fromMeshData(MeshData.build(positions: _f32(p), normals: _f32(n), texCoords: _f32(uv)));
}

/// A node placed at a DeskDef's spot and turned its way.
Node atDesk(DeskDef def) => Node(name: def.id)
  ..position = vm.Vector3(def.x, 0, def.z)
  ..rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), def.rotY);
