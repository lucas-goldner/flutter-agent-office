// The building dressed up for a holiday (the costumes are in costumes.dart): a port of
// world/holiday.ts. Halloween puts jack-o'-lanterns everywhere, on the desks, the sills, the counter,
// the balcony rail and all down the street, with gravestones on the lawn, cobwebs in the corners and
// bats circling the building and crossing the moon. Christmas turns the potted plants into little
// decorated trees with presents under them, puts a present on every desk, a big lit tree out front
// and snowmen in the snow (the sky makes it snow, see SkyModel.setTheme).
//
// What goes where is [HolidayPlan] (plain numbers, tested); [Holiday] builds each holiday's things
// the first time it's put up, and shows them while it's on. What's down on the street goes further
// down the higher your floor is, as the street does ([Holiday.setStreetDrop]).

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart' show HolidayTheme;
import 'package:vector_math/vector_math.dart' as vm;

import 'character.dart' show setEmissive;
import 'collider.dart';
import 'costumes.dart';
import 'geo.dart';
import 'office/office_colliders.dart' show roomPlants;
import 'sky_model.dart' show kSpookyMoonAz, kSpookyMoonEl;
import 'text.dart';
import 'toon.dart';

const double _g = streetY;

/// Somewhere to put something: its foot at (x, y, z), [r] its size, turned so its front (+z) faces [rotY].
typedef Spot = ({double x, double y, double z, double r, double rotY});

Spot _spot(double x, double y, double z, double r, double rotY) => (x: x, y: y, z: z, r: r, rotY: rotY);

abstract final class _Face {
  static const double south = 0, north = math.pi, east = math.pi / 2, west = -math.pi / 2;
}

/// A point [lx] along and [lz] out from a desk's middle, in its own frame (see DeskDef.rotY).
(double, double) onDesk(DeskDef d, double lx, double lz) {
  final c = math.cos(d.rotY), s = math.sin(d.rotY);
  return (d.x + lx * c + lz * s, d.z - lx * s + lz * c);
}

/// On every desk, in the back corner its own knick-knack leaves free (see buildDesk), facing whoever sits there.
List<Spot> deskSpots() => [
  for (final (i, d) in desks.indexed)
    () {
      final (x, z) = onDesk(d, i % 3 == 1 ? 0.78 : -0.78, -0.28);
      return _spot(x, DeskSize.height, z, 0.12, d.rotY);
    }(),
];

/// Jack-o'-lanterns: everywhere.
List<Spot> pumpkinSpots() {
  final spots = [...deskSpots()];
  // The kitchen counter, and the lounge's coffee table.
  spots.addAll([
    _spot(-13, 1.03, 12.2, 0.14, _Face.north),
    _spot(-16.65, 1.03, 12.25, 0.11, _Face.north),
    _spot(13, 0.46, 0.25, 0.17, _Face.west),
  ]);
  // On the window sills, looking in.
  for (final o in windows) {
    if (o.y0 > 2) continue;
    if (o.wall == Side.south) spots.add(_spot(o.u - 0.85, o.y0, Floor.maxZ - 0.08, 0.1, _Face.north));
    if (o.wall == Side.west) spots.add(_spot(Floor.minX + 0.08, o.y0, o.u + 0.85, 0.1, _Face.east));
  }
  // Beside every potted plant, toward the middle of the room.
  for (final (x, z, s) in roomPlants) {
    final d = math.sqrt(x * x + z * z);
    final k = d == 0 ? 1.0 : d;
    spots.add(_spot(x - (x / k) * 0.55 * s, 0, z - (z / k) * 0.55 * s, 0.2 * s, math.atan2(-x, -z)));
  }
  // Under the TV, beside the elevator, out on the balcony and on the landing outside the exit.
  spots.addAll([
    _spot(17.55, 0, -2.4, 0.22, _Face.west),
    _spot(17.6, 0, 2.3, 0.17, _Face.west),
    _spot(10.35, 0, Floor.minZ + 0.4, 0.22, _Face.south),
  ]);
  for (final x in const [-9.3, -5.8, -2.2, 1.4]) {
    spots.add(_spot(x, 1.105, Balcony.maxZ - 0.06, 0.13, _Face.north));
  }
  // (Only the south-east corner: the south-west one has the balcony's potted plant.)
  spots.add(_spot(Balcony.maxX - 0.4, 0, Balcony.maxZ - 0.4, 0.2, _Face.north));
  spots.add(_spot(ExitStairs.minX + 0.3, 0, ExitStairs.landingZ0 + 0.25, 0.17, _Face.south));
  // Down the street, at the foot of every lamp, facing the office.
  for (final x in const [-40.0, -28.0, -16.0, -4.0, 8.0, 16.0, 28.0, 40.0]) {
    spots.add(_spot(x + 0.6, _g + 0.04, 21.7, 0.3, _Face.north));
  }
  for (final x in const [-34.0, -22.0, -4.0, 8.0, 26.0, 36.0]) {
    spots.add(_spot(x + 0.6, _g + 0.04, 32.3, 0.3, _Face.north));
  }
  // Heaps of them out front, either side of the garage, and at the balcony's posts.
  for (final sx in const [-1.0, 1.0]) {
    spots.addAll([
      _spot(sx * 17.2, _g, 19.2, 0.55, _Face.north),
      _spot(sx * 18.3, _g, 19.6, 0.38, _Face.north + sx * 0.4),
      _spot(sx * 16.3, _g, 19.9, 0.3, _Face.north - sx * 0.3),
    ]);
  }
  spots.addAll([
    _spot(Balcony.minX + 0.75, _g, Balcony.maxZ - 0.2, 0.36, _Face.south),
    _spot(Balcony.maxX - 0.75, _g, Balcony.maxZ - 0.2, 0.36, _Face.south),
  ]);
  // Among the graves.
  spots.addAll([
    _spot(-22.4, _g, -2.2, 0.32, _Face.east),
    _spot(-22.6, _g, 4.6, 0.26, _Face.east),
    _spot(-24.6, _g, 1.3, 0.3, _Face.east),
  ]);
  return spots;
}

/// Down on the street (or out past the west wall, on the bottom floor's landing): goes down with the street.
bool isDown(Spot s) => s.y < 0 || s.x < Floor.minX;

/// Where the gravestones stand, on the lawn west of the office, facing its windows.
const List<(double x, double z, int kind)> graves = [
  (-23.2, -3.4, 0),
  (-23.4, -0.4, 1),
  (-23.1, 2.8, 2),
  (-23.3, 6, 0),
  (-25.8, -1.8, 2),
  (-25.9, 1.4, 1),
  (-25.7, 4.5, 0),
];

/// Where the snowmen stand, out front and round the side.
const List<(double x, double z, double rotY)> snowmen = [
  (-14, 18.6, 0.2),
  (13, 19.2, -0.3),
  (25.5, 6, -math.pi / 2 + 0.3),
  (-23.5, 2, math.pi / 2),
];

/// The big tree out front, on the lot by the sidewalk.
abstract final class BigTree {
  static const double x = -24, z = 17, height = 7.5;
}

/// What a holiday puts up, as numbers: where each thing goes, and what can't be walked through.
class HolidayPlan {
  HolidayPlan._(this.theme, this.pumpkins, this.gifts, this.plantTrees, this.colliders);

  factory HolidayPlan(HolidayTheme theme) {
    final colliders = <Collider>[];
    if (theme == HolidayTheme.halloween) {
      for (final (x, z, _) in graves) {
        colliders.add(
          Collider(minX: x - 0.3, maxX: x + 0.3, minZ: z - 0.45, maxZ: z + 0.45, bottom: _g, top: _g + 1.2),
        );
      }
      return HolidayPlan._(theme, pumpkinSpots(), const [], const [], colliders);
    }
    colliders.add(
      Collider(
        minX: BigTree.x - 1.5,
        maxX: BigTree.x + 1.5,
        minZ: BigTree.z - 1.5,
        maxZ: BigTree.z + 1.5,
        bottom: _g,
        top: _g + BigTree.height,
      ),
    );
    for (final (x, z, _) in snowmen) {
      colliders.add(
        Collider(minX: x - 0.55, maxX: x + 0.55, minZ: z - 0.55, maxZ: z + 0.55, bottom: _g, top: _g + 2.5),
      );
    }
    return HolidayPlan._(theme, const [], deskSpots(), roomPlants, colliders);
  }

  final HolidayTheme theme;

  /// Jack-o'-lanterns (Halloween).
  final List<Spot> pumpkins;

  /// A present on every desk (Christmas).
  final List<Spot> gifts;

  /// The potted plants that become little trees (Christmas): x, z, scale.
  final List<(double, double, double)> plantTrees;

  /// Gravestones, or the big tree and the snowmen: all down on the street.
  final List<Collider> colliders;
}

// ---- Jack-o'-lanterns ---------------------------------------------------------------------------

/// The pumpkin's shape: a unit sphere point (x, y, z) squashed and ribbed, sitting on y = 0.
vm.Vector3 _pumpkinPoint(double x, double y, double z) {
  final a = math.atan2(x, z);
  final rib = 1 + 0.06 * math.cos(10 * a) * math.sqrt(math.max(0, 1 - y * y));
  // Squat, with a dimple on top where the stem goes.
  final dimple = y > 0.8 ? (y - 0.8) * 0.9 : 0.0;
  return vm.Vector3(x * rib, (y - dimple) * 0.78 + 0.78, z * rib);
}

/// A ribbed pumpkin 2 m across, sitting on y = 0.
GeoData _pumpkinData() {
  final g = sphereData(1, 24, 14);
  for (var i = 0; i < g.count; i++) {
    final v = _pumpkinPoint(g.p[i * 3], g.p[i * 3 + 1], g.p[i * 3 + 2]);
    g.p.setRange(i * 3, i * 3 + 3, [v.x, v.y, v.z]);
  }
  return g;
}

/// The carved face's holes, in the old canvas's pixels (512 round the pumpkin, 256 top to bottom).
const List<List<(double, double)>> _faceShapes = [
  // Slanted triangle eyes.
  [(70, 112), (118, 110), (100, 76)],
  [(138, 110), (186, 112), (156, 76)],
  // A nose.
  [(118, 132), (138, 132), (128, 116)],
  // A jagged grin with two teeth.
  [
    (66, 140), (92, 150), (100, 140), (110, 154), (146, 154), (156, 140), (164, 150), (190, 140), //
    (178, 164), (154, 180), (128, 184), (102, 180), (78, 164),
  ],
];

/// The candlelit face: its holes laid on the pumpkin's front, split small enough to follow its curve.
GeoData _faceData() {
  final g = GeoData();
  vm.Vector3 onSkin(vm.Vector2 c) {
    final phi = c.x / 512 * math.pi * 2, theta = c.y / 256 * math.pi;
    final x = -math.cos(phi) * math.sin(theta), y = math.cos(theta), z = math.sin(phi) * math.sin(theta);
    final p = _pumpkinPoint(x, y, z);
    // Just proud of the skin.
    final out = vm.Vector3(p.x, p.y - 0.78, p.z)..normalize();
    return p + out * 0.02;
  }

  void tri(vm.Vector2 a, vm.Vector2 b, vm.Vector2 c, int depth) {
    if (depth > 0) {
      final ab = (a + b) * 0.5, bc = (b + c) * 0.5, ca = (c + a) * 0.5;
      tri(a, ab, ca, depth - 1);
      tri(ab, b, bc, depth - 1);
      tri(ca, bc, c, depth - 1);
      tri(ab, bc, ca, depth - 1);
      return;
    }
    final ids = [
      for (final p in [a, b, c])
        () {
          final v = onSkin(p);
          final n = vm.Vector3(v.x, v.y - 0.78, v.z)..normalize();
          return g.vertex(v.x, v.y, v.z, n.x, n.y, n.z);
        }(),
    ];
    g.tri(ids[0], ids[1], ids[2]);
  }

  for (final shape in _faceShapes) {
    final pts = [for (final (x, y) in shape) vm.Vector2(x, y)];
    for (final (a, b, c) in triangulate(pts)) {
      tri(pts[a], pts[b], pts[c], 2);
    }
  }
  return g;
}

// ---- Gravestones, cobwebs, bats -----------------------------------------------------------------

/// A gravestone (a rounded slab, a cross, or a squat marker) with a mound of earth in front, facing +z.
Node _gravestone(int kind) {
  final g = Node(name: 'grave');
  final stone = toon(hex('#9a9ca8'));
  if (kind == 1) {
    g.add(mesh(box(0.16, 1.2, 0.14), stone, 0, 0.6, 0));
    g.add(mesh(box(0.62, 0.16, 0.14), stone, 0, 0.85, 0));
  } else {
    final w = kind == 2 ? 0.8 : 0.62;
    final h = kind == 2 ? 0.45 : 0.72;
    g.add(mesh(box(w, h, 0.16), stone, 0, h / 2, 0));
    // The rounded top: a disc, its lower half inside the slab.
    g.add(mesh(cylinderData(w / 2, w / 2, 0.16, 20).rotateX(math.pi / 2).build(), stone, 0, h, 0));
  }
  g.add(mesh(sphere(0.55, 14, 8), toon(hex('#5b4636')), 0, -0.02, 0.75)..scale = vm.Vector3(0.8, 0.22, 1.35));
  g.rotation = euler(0, 0, (kind - 1) * 0.07);
  return g;
}

/// A web strung across a top corner of the room, where the walls meet the ceiling at (x, z): its
/// threads as thin strips in the triangle the old one's texture was drawn on.
Node _cobweb(double x, double z, Material mat) {
  final sx = x.sign, sz = z.sign;
  const h = wallHeight - 0.02, span = 2.2;
  // The corners of the old texture's triangle: uv (0, 1), (1, 1) and (0.5, 0).
  final a = vm.Vector3(x - sx * span, h, z), b = vm.Vector3(x, h, z - sz * span), c = vm.Vector3(x, h - span * 1.1, z);
  // uv → the triangle's plane (affine): P = o + u·U + v·V.
  final uAxis = b - a;
  final o = c - uAxis * 0.5;
  final vAxis = a - o;
  vm.Vector3 at(double px, double py) => o + uAxis * (px / 256) + vAxis * (1 - py / 256);
  bool inTri(double px, double py) {
    final u = px / 256, v = 1 - py / 256;
    // Inside (0,1)-(1,1)-(0.5,0): v ≤ 1 and within the two slanted edges.
    return v <= 1 && v >= 0 && u >= 0.5 - v / 2 && u <= 0.5 + v / 2;
  }

  final g = GeoData();
  final normal = uAxis.cross(vAxis)..normalize();
  void strand(double x0, double y0, double x1, double y1) {
    if (!inTri(x0, y0) || !inTri(x1, y1)) return;
    final p0 = at(x0, y0), p1 = at(x1, y1);
    final along = p1 - p0;
    if (along.length < 1e-6) return;
    final side = normal.cross(along.normalized())..scale(0.006);
    final i0 = g.vertex(p0.x - side.x, p0.y - side.y, p0.z - side.z, normal.x, normal.y, normal.z);
    final i1 = g.vertex(p0.x + side.x, p0.y + side.y, p0.z + side.z, normal.x, normal.y, normal.z);
    final i2 = g.vertex(p1.x + side.x, p1.y + side.y, p1.z + side.z, normal.x, normal.y, normal.z);
    final i3 = g.vertex(p1.x - side.x, p1.y - side.y, p1.z - side.z, normal.x, normal.y, normal.z);
    g.tri(i0, i1, i2);
    g.tri(i0, i2, i3);
  }

  const hub = (128.0, 70.0);
  final ends = <(double, double)>[
    for (var i = 0; i <= 10; i++)
      () {
        final a = -0.1 + i / 10 * (math.pi + 0.2);
        return (hub.$1 + math.cos(a) * 260, hub.$2 + math.sin(a) * 260);
      }(),
  ];
  // The spokes, in short pieces so the ones running off the triangle stop at its edge.
  for (final (ex, ey) in ends) {
    for (var k = 0; k < 20; k++) {
      final t0 = k / 20, t1 = (k + 1) / 20;
      strand(
        hub.$1 + (ex - hub.$1) * t0,
        hub.$2 + (ey - hub.$2) * t0,
        hub.$1 + (ex - hub.$1) * t1,
        hub.$2 + (ey - hub.$2) * t1,
      );
    }
  }
  // The rings, sagging a little between the spokes.
  for (var r = 18.0; r < 240; r *= 1.32) {
    final k = r / 260;
    for (var i = 1; i < ends.length; i++) {
      final (x0, y0) = ends[i - 1];
      final (x1, y1) = ends[i];
      final ax = hub.$1 + (x0 - hub.$1) * k, ay = hub.$2 + (y0 - hub.$2) * k;
      final bx = hub.$1 + (x1 - hub.$1) * k, by = hub.$2 + (y1 - hub.$2) * k;
      final mx = hub.$1 + ((x1 + x0) / 2 - hub.$1) * k * 0.9, my = hub.$2 + ((y1 + y0) / 2 - hub.$2) * k * 0.9;
      var px = ax, py = ay;
      for (var s = 1; s <= 4; s++) {
        final t = s / 4, u = 1 - t;
        final qx = u * u * ax + 2 * u * t * mx + t * t * bx, qy = u * u * ay + 2 * u * t * my + t * t * by;
        strand(px, py, qx, qy);
        px = qx;
        py = qy;
      }
    }
  }
  return mesh(g.build(), mat, 0, 0, 0, false);
}

class _Bat {
  _Bat(
    this.root,
    this.wings, {
    required this.cx,
    required this.cz,
    required this.r,
    required this.y,
    required this.speed,
    required this.phase,
  });
  final Node root;
  final List<Pivot> wings;

  /// Round (cx, cz) at radius r, [speed] radians a second (the sign is which way), at height y.
  final double cx, cz, r, y, speed, phase;
}

/// A bat: a black silhouette with flapping wings, flying toward +z.
({Node root, List<Pivot> wings}) _bat(Material mat, Geometry wing, double scale) {
  final root = Node(name: 'bat');
  root.add(mesh(sphere(0.12, 10, 8), mat, 0, 0, 0, false)..scale = vm.Vector3(0.8, 0.75, 1.3));
  root.add(mesh(sphere(0.08, 10, 8), mat, 0, 0.03, 0.16, false));
  for (final sx in const [-1.0, 1.0]) {
    root.add(mesh(cone(0.03, 0.08, 6), mat, sx * 0.04, 0.1, 0.16, false)..rotation = euler(0, 0, -sx * 0.3));
  }
  final wings = <Pivot>[];
  for (final sx in const [-1.0, 1.0]) {
    final pivot = Pivot()..position = vm.Vector3(sx * 0.06, 0.02, 0.04);
    pivot.add(mesh(wing, mat, 0, 0, 0, false)..scale = vm.Vector3(sx, 1, 1));
    root.add(pivot.node);
    wings.add(pivot);
  }
  root.scale = vm.Vector3.all(scale);
  return (root: root, wings: wings);
}

// ---- Christmas ----------------------------------------------------------------------------------

/// A decorated Christmas tree [h] tall standing at 0,0,0: tiers of branches, baubles, lights and a
/// star.
Node _christmasTree(double h, List<Material> lights, {bool trunk = false, int seed = 1}) {
  final g = Node(name: 'xmas-tree');
  final greens = [toon(hex('#1f7a3a')), toon(hex('#2a9d4b')), toon(hex('#23884a'))];
  const tiers = 4;
  final base = trunk ? h * 0.1 : 0.0;
  if (trunk) g.add(mesh(cylinder(h * 0.035, h * 0.045, base + 0.1, 10), toon(hex('#6b4226')), 0, (base + 0.1) / 2, 0));
  final tierH = (h - base) * 0.92 / (tiers * 0.72);
  final baubles = [
    for (final c in const ['#e63946', '#ffd166', '#4cc9f0', '#f1faee', '#c77dff']) toon(hex(c)),
  ];
  final rand = math.Random(seed);
  final bauble = sphere(h * 0.024, 10, 8), bulb = sphere(h * 0.013, 8, 6);
  for (var i = 0; i < tiers; i++) {
    final r = h * 0.34 * (tiers - i) / tiers + h * 0.05;
    final y0 = base + i * tierH * 0.72;
    g.add(mesh(cone(r, tierH, 14), greens[i % 3], 0, y0 + tierH / 2, 0));
    // Baubles and lights round the tier's lower edge, where the branches stick out.
    final n = 5 + (tiers - i) * 2;
    for (var j = 0; j < n; j++) {
      final a = j / n * math.pi * 2 + i;
      final up = 0.08 + rand.nextDouble() * 0.35;
      final rr = r * (1 - up) + h * 0.006;
      final y = y0 + tierH * up;
      if (j.isOdd) {
        g.add(mesh(bauble, baubles[(i + j) % baubles.length], math.cos(a) * rr, y, math.sin(a) * rr, false));
      } else {
        final out = rr + h * 0.004;
        g.add(
          mesh(
            bulb,
            lights[(i + j ~/ 2) % lights.length],
            math.cos(a) * out,
            y + tierH * 0.05,
            math.sin(a) * out,
            false,
          ),
        );
      }
    }
  }
  // A gold star on top, two flat ones crossed.
  final star = <vm.Vector2>[
    for (var i = 0; i < 10; i++)
      vm.Vector2(
        math.cos(i / 10 * math.pi * 2 + math.pi / 2) * (i.isOdd ? 0.45 : 1) * h * 0.07,
        math.sin(i / 10 * math.pi * 2 + math.pi / 2) * (i.isOdd ? 0.45 : 1) * h * 0.07,
      ),
  ];
  final gold = toonUnique(hex('#ffd166'))..doubleSided = true;
  setEmissive(gold, hex('#ffb000'), 0.6);
  final starGeo = shapeData(star).build();
  final top = base + tierH * 0.72 * (tiers - 1) + tierH + h * 0.04;
  g.add(mesh(starGeo, gold, 0, top, 0, false));
  g.add(mesh(starGeo, gold, 0, top, 0, false)..rotation = euler(0, math.pi / 2));
  return g;
}

/// A wrapped present [w] across, sitting on y = 0.
Node _present(double w, String paper, String ribbon) {
  final g = Node(name: 'present');
  final h = w * 0.8;
  g.add(mesh(box(w, h, w), toon(hex(paper)), 0, h / 2, 0));
  final rib = toon(hex(ribbon));
  g.add(mesh(box(w * 1.02, h * 1.02, w * 0.18), rib, 0, h / 2, 0, false));
  g.add(mesh(box(w * 0.18, h * 1.02, w * 1.02), rib, 0, h / 2, 0, false));
  for (final sx in const [-1.0, 1.0]) {
    g.add(
      mesh(torus(w * 0.15, w * 0.05, 6, 12), rib, sx * w * 0.13, h + w * 0.1, 0, false)
        ..rotation = euler(sx * 0.4, math.pi / 2),
    );
  }
  return g;
}

const List<(String, String)> _papers = [
  ('#e63946', '#ffd166'),
  ('#2a9d4b', '#e63946'),
  ('#4cc9f0', '#fffaf3'),
  ('#ffd166', '#c1121f'),
  ('#c77dff', '#ffd166'),
];

/// A snowman with a scarf, a carrot nose, coal eyes and buttons, twig arms and a top hat, facing +z.
Node _snowman() {
  final g = Node(name: 'snowman');
  final snow = toon(hex('#f4f8ff'));
  final coal = toon(hex('#23232b'));
  final twig = toon(hex('#6b4226'));
  for (final (r, y) in const [(0.55, 0.5), (0.4, 1.28), (0.28, 1.86)]) {
    g.add(mesh(sphere(r, 18, 14), snow, 0, y, 0));
  }
  for (final sx in const [-1.0, 1.0]) {
    g.add(mesh(sphere(0.04, 8, 6), coal, sx * 0.1, 1.94, 0.24, false));
  }
  g.add(mesh(coneData(0.05, 0.3, 10).rotateX(math.pi / 2).build(), toon(hex('#ff8c1a')), 0, 1.86, 0.4, false));
  for (var i = 0; i < 3; i++) {
    g.add(mesh(sphere(0.045, 8, 6), coal, 0, 1.12 + i * 0.16, 0.39 - (i - 1).abs() * 0.02, false));
  }
  final red = toon(hex('#d62828'));
  g.add(mesh(torus(0.29, 0.07, 8, 20), red, 0, 1.6, 0)..rotation = euler(math.pi / 2, 0));
  g.add(mesh(box(0.14, 0.4, 0.05), red, 0.18, 1.42, 0.24)..rotation = euler(0, 0, 0.2));
  for (final sx in const [-1.0, 1.0]) {
    g.add(mesh(cylinder(0.025, 0.035, 0.9, 6), twig, sx * 0.72, 1.45, 0, false)..rotation = euler(0, 0, sx * 1.05));
  }
  g.add(mesh(cylinder(0.34, 0.34, 0.04, 20), coal, 0, 2.1, 0));
  g.add(mesh(cylinder(0.22, 0.22, 0.4, 20), coal, 0, 2.3, 0));
  g.add(mesh(cylinder(0.225, 0.225, 0.07, 20), red, 0, 2.16, 0, false));
  return g;
}

Node _placed(Node n, Spot s) => n
  ..position = vm.Vector3(s.x, s.y, s.z)
  ..rotation = euler(0, s.rotY)
  ..scale = vm.Vector3.all(s.r);

// -----------------------------------------------------------------------------------------------

class Holiday {
  /// [colliders] is the office's list: a holiday's go in while it's up. [plantLeaves] is hidden while
  /// the plants are Christmas trees.
  Holiday({required this.colliders, this.plantLeaves});

  final List<Collider> colliders;
  final Node? plantLeaves;
  final Node group = Node(name: 'holiday');
  HolidayTheme? theme;

  /// Each holiday's things, built the first time it's put up: in the office, and down on the street.
  final Map<HolidayTheme, ({Node inside, Node street, HolidayPlan plan})> _built = {};
  final Map<Collider, (double, double)> _base = {};
  double _drop = 0;

  // Halloween.
  PreprocessedMaterial? _faceGlow;
  final List<_Bat> _bats = [];

  /// Bats far off round the moon, which ride along with you like the moon does.
  final Node _moonBats = Node(name: 'moon-bats');

  // Christmas.
  final List<PreprocessedMaterial> _lights = [];

  bool shown(HolidayTheme t) => _built[t]?.inside.visible ?? false;

  /// Puts up a holiday's decorations (taking down the other's), or none.
  void set(HolidayTheme? next) {
    if (next == theme) return;
    final was = theme;
    if (was != null) {
      final b = _built[was]!;
      b.inside.visible = b.street.visible = false;
      for (final c in b.plan.colliders) {
        colliders.remove(c);
      }
    }
    theme = next;
    if (next != null) {
      final b = _built[next] ??= _build(next);
      b.inside.visible = b.street.visible = true;
      colliders.addAll(b.plan.colliders);
    }
    plantLeaves?.visible = next != HolidayTheme.christmas;
  }

  /// The street is [drop] further down than from the bottom floor (a storey for each floor below yours).
  void setStreetDrop(double drop) {
    if (drop == _drop) return;
    _drop = drop;
    for (final b in _built.values) {
      b.street.position = vm.Vector3(0, -drop, 0);
    }
    for (final e in _base.entries) {
      e.key.top = e.value.$1 - drop;
    }
  }

  ({Node inside, Node street, HolidayPlan plan}) _build(HolidayTheme t) {
    final plan = HolidayPlan(t);
    final inside = Node(name: '${t.wire}-inside'), street = Node(name: '${t.wire}-street');
    group
      ..add(inside)
      ..add(street);
    street.position = vm.Vector3(0, -_drop, 0);
    for (final c in plan.colliders) {
      _base[c] = (c.top, c.bottom ?? 0);
      c.top -= _drop;
    }
    t == HolidayTheme.halloween ? _buildHalloween(plan, inside, street) : _buildChristmas(plan, inside, street);
    return (inside: inside, street: street, plan: plan);
  }

  void _buildHalloween(HolidayPlan plan, Node inside, Node street) {
    final skin = toon(hex('#f28a1d'));
    final glow = _faceGlow = toonUnique(hex('#ffd23f'));
    setEmissive(glow, hex('#ffb347'), 0.5);
    final body = _pumpkinData().build();
    final face = _faceData().build();
    final stem = cylinderData(
      0.09,
      0.15,
      0.4,
      7,
    ).transform(vm.Matrix4.translationValues(0, 1.6, 0) * vm.Matrix4.rotationZ(0.12) as vm.Matrix4).build();
    final stemMat = toon(hex('#5b6e2a'));
    for (final (down, into) in [(false, inside), (true, street)]) {
      final heap = Node(name: 'pumpkins');
      for (final s in plan.pumpkins.where((s) => isDown(s) == down)) {
        final p = Node(name: 'pumpkin')
          ..add(mesh(body, skin))
          ..add(mesh(face, glow, 0, 0, 0, false))
          ..add(mesh(stem, stemMat));
        heap.add(_placed(p, s));
      }
      into.add(mergeByMaterial(heap));
    }

    final stones = Node(name: 'graves');
    for (final (x, z, kind) in graves) {
      final s = _gravestone(kind)
        ..position = vm.Vector3(x, _g, z)
        ..rotation = euler(0, _Face.east + (kind - 1) * 0.12);
      stones.add(s);
      if (kind != 1) {
        final label = textPlane('R.I.P.', const TextOpts(size: 56));
        label
          ..scale = vm.Vector3.all(kind == 2 ? 0.55 : 0.45)
          ..position = vm.Vector3(x + 0.09, _g + (kind == 2 ? 0.28 : 0.5), z)
          ..rotation = euler(0, _Face.east + (kind - 1) * 0.12);
        street.add(label);
      }
    }
    street.add(mergeByMaterial(stones));

    final web = basic(hex('#e9e9f4'))..doubleSided = true;
    for (final (x, z) in const [(Floor.minX, Floor.minZ), (Floor.maxX, Floor.minZ), (Floor.minX, Floor.maxZ)]) {
      inside.add(_cobweb(x, z, web));
    }

    final batMat = basic(hex('#150b1f'))..doubleSided = true;
    final wing = batWingGeometry(0.6);
    final rand = math.Random(31);
    for (var i = 0; i < 12; i++) {
      final b = _bat(batMat, wing, 1.2 + rand.nextDouble() * 0.8);
      inside.add(b.root);
      _bats.add(
        _Bat(
          b.root,
          b.wings,
          cx: (rand.nextDouble() - 0.5) * 6,
          cz: (rand.nextDouble() - 0.5) * 6,
          r: 23 + rand.nextDouble() * 12,
          y: 2.5 + rand.nextDouble() * 9,
          speed: (0.15 + rand.nextDouble() * 0.15) * (i % 3 != 0 ? 1 : -1),
          phase: rand.nextDouble() * 7,
        ),
      );
    }
    // Against the moon: 70 m off in its direction, so they cross it now and then.
    final farMat = basic(hex('#0d0612'))..doubleSided = true;
    final toMoon = vm.Vector3(
      math.cos(kSpookyMoonEl) * math.sin(kSpookyMoonAz),
      math.sin(kSpookyMoonEl),
      -math.cos(kSpookyMoonEl) * math.cos(kSpookyMoonAz),
    )..scale(70);
    for (var i = 0; i < 4; i++) {
      final b = _bat(farMat, wing, 2.4);
      _moonBats.add(b.root);
      _bats.add(
        _Bat(
          b.root,
          b.wings,
          cx: toMoon.x,
          cz: toMoon.z,
          r: 3 + rand.nextDouble() * 4,
          y: toMoon.y + (rand.nextDouble() - 0.5) * 3,
          speed: (0.6 + rand.nextDouble() * 0.4) * (i.isOdd ? 1 : -1),
          phase: rand.nextDouble() * 7,
        ),
      );
    }
    inside.add(_moonBats);
  }

  void _buildChristmas(HolidayPlan plan, Node inside, Node street) {
    for (final c in const ['#ffe28a', '#ff5a5a', '#6ec3ff', '#7dff8a']) {
      final m = toonUnique(hex(c));
      setEmissive(m, hex(c), 0.6);
      _lights.add(m);
    }
    // The potted plants become little trees, with presents round the pot.
    final trees = Node(name: 'plant-trees');
    for (final (i, (x, z, s)) in plan.plantTrees.indexed) {
      final tree = Node()
        ..position = vm.Vector3(x, 0, z)
        ..scale = vm.Vector3.all(s);
      tree.add(_christmasTree(1.25, _lights, seed: i + 1)..position = vm.Vector3(0, 0.45, 0));
      for (final (gx, gz, w, rot) in const [
        (0.45, 0.2, 0.26, 0.3),
        (-0.3, 0.42, 0.2, -0.5),
        (0.12, -0.46, 0.22, 0.9),
      ]) {
        final (paper, ribbon) = _papers[(i + (w * 10).round()) % _papers.length];
        tree.add(
          _present(w, paper, ribbon)
            ..position = vm.Vector3(gx, 0, gz)
            ..rotation = euler(0, rot),
        );
      }
      trees.add(tree);
    }
    inside.add(mergeByMaterial(trees));
    // A present on every desk.
    final gifts = Node(name: 'desk-gifts');
    for (final (i, s) in plan.gifts.indexed) {
      final (paper, ribbon) = _papers[i % _papers.length];
      gifts.add(
        _present(0.17, paper, ribbon)
          ..position = vm.Vector3(s.x, s.y, s.z)
          ..rotation = euler(0, s.rotY + 0.3),
      );
    }
    inside.add(mergeByMaterial(gifts));
    // The big tree out front, lit up, with a heap of presents.
    final out = Node(name: 'big-tree');
    out.add(_christmasTree(BigTree.height, _lights, trunk: true, seed: 75));
    for (var i = 0; i < 7; i++) {
      final a = i * 0.9 + 0.4;
      final w = 0.45 + (i % 3) * 0.15;
      final (paper, ribbon) = _papers[i % _papers.length];
      out.add(
        _present(w, paper, ribbon)
          ..position = vm.Vector3(math.cos(a) * 1.9, 0, math.sin(a) * 1.9)
          ..rotation = euler(0, a),
      );
    }
    street.add(mergeByMaterial(out)..position = vm.Vector3(BigTree.x, _g, BigTree.z));
    final men = Node(name: 'snowmen');
    for (final (x, z, rotY) in snowmen) {
      men.add(
        _snowman()
          ..position = vm.Vector3(x, _g, z)
          ..rotation = euler(0, rotY),
      );
    }
    street.add(mergeByMaterial(men));
  }

  /// [lampsOn] is how far the lamps are on (see SkyModel), 0 by day and 1 at night: the candles and
  /// the tree lights glow brighter. [cam] is where the camera is, in the office's space.
  void update(double t, double lampsOn, vm.Vector3 cam) {
    if (theme == HolidayTheme.halloween) {
      // Candlelight: a slow flicker, and now and then a gutter.
      final flicker = 0.88 + 0.08 * math.sin(t * 7.3) + 0.05 * math.sin(t * 17.1) + 0.04 * math.sin(t * 29.7);
      final glow = _faceGlow;
      if (glow != null) setEmissive(glow, hex('#ffb347'), (0.45 + 0.9 * lampsOn) * flicker);
      _moonBats.position = cam.clone();
      for (final b in _bats) {
        final a = b.phase + t * b.speed;
        final dir = b.speed.sign;
        b.root
          ..position = vm.Vector3(
            b.cx + math.cos(a) * b.r,
            b.y + math.sin(t * 0.9 + b.phase) * 1.2,
            b.cz + math.sin(a) * b.r,
          )
          // Along the circle, the way it's going, banking into the turn.
          ..rotation = euler(0, math.atan2(-math.sin(a) * dir, math.cos(a) * dir), dir * 0.35);
        final flap = math.sin(t * 16 + b.phase * 3);
        for (final (i, w) in b.wings.indexed) {
          w
            ..z = (i > 0 ? 1 : -1) * (0.15 + flap * 0.65)
            ..apply();
        }
      }
    } else if (theme == HolidayTheme.christmas) {
      final base = 0.35 + 0.9 * lampsOn;
      for (final (i, m) in _lights.indexed) {
        setEmissive(m, _lightColors[i], base * (0.55 + 0.45 * math.sin(t * 2.2 + i * 1.7)));
      }
    }
  }

  static final _lightColors = [
    for (final c in const ['#ffe28a', '#ff5a5a', '#6ec3ff', '#7dff8a']) hex(c),
  ];
}
