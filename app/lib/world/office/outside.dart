// Downstairs and outdoors: the open garage under the office with its cars, and the street, lamps,
// trees, neighbours and clouds (a port of outside.ts). Also what the sky drives at night: NightParts.

import 'dart:math' as math;
import 'dart:ui' show Color, Offset, Path, Rect;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;

import '../text.dart';
import '../toon.dart';
import 'cars.dart';
import 'geo.dart';
import 'office_colliders.dart';
import 'parts.dart';

const double _g = streetY;

/// Parking bays are this wide; the rows of them start at x = -16.
const double _bay = 3.2;

/// A light that throws a pool of light around it at night (see sky.ts): where, how far, and its colour.
class Lamp {
  const Lamp({
    required this.x,
    required this.y,
    required this.z,
    required this.reach,
    required this.color,
    required this.power,
    this.ground = false,
  });

  final double x;
  final double y;
  final double z;
  final double reach;
  final String color;

  /// How bright, at the middle of the pool.
  final double power;

  /// Down by the street (a street lamp, the one over the exit): it's further down the higher your floor is.
  final bool ground;
}

/// A bulb whose glow goes from [day] (by day) up to full at night.
class NightBulb {
  NightBulb(this.mat, this.color, this.day);

  final PreprocessedMaterial mat;
  final Color color;
  final double day;

  /// Sets its glow: [k] 0 is its daytime glow, 1 full.
  void glow(double k) => setEmissive(mat, color, day + (1 - day) * k);
}

/// Where a bulb's soft halo goes at night, and its colour.
class Halo {
  const Halo({required this.at, required this.size, required this.color, this.ground = false});

  final vm.Vector3 at;
  final double size;
  final String color;

  /// Down by the street, as for a [Lamp].
  final bool ground;
}

/// Everything that changes between day and night and with the weather, for the sky to drive.
class NightParts {
  NightParts()
    : clouds = toonUnique(const Color(0xFFFFFFFF)),
      wetGlass = UnlitMaterial()
        ..alphaMode = AlphaMode.blend
        ..baseColorFactor = vm.Vector4(1, 1, 1, 0);

  final List<NightBulb> bulbs = [];

  /// How far below the floor you're on the street is (see streetBelow): what the `ground` lamps drop with.
  double street = streetY;
  final List<Halo> halos = [];
  final List<Lamp> lamps = [];

  /// The neighbours' lit windows: an unlit overlay on each building's walls, clear by day. The
  /// sky fades them in (its alpha) as the old client raised their emissiveIntensity.
  final List<UnlitMaterial> windows = [];
  final PreprocessedMaterial clouds;

  /// Rain running down the office windows: the sky gives it a texture and shows [wetPanes].
  final UnlitMaterial wetGlass;
  final List<Node> wetPanes = [];

  /// How lit the neighbours' windows are, 0 by day to 1 at night.
  void setWindowsLit(double k) {
    for (final m in windows) {
      m.baseColorFactor = vm.Vector4(1, 1, 1, k.clamp(0, 1));
    }
  }
}

/// A bulb that glows [day] much by day and fully at night.
PreprocessedMaterial bulb(NightParts night, String color, [double day = 0]) {
  final c = hex(color);
  final mat = toonUnique(c);
  setEmissive(mat, c, day);
  night.bulbs.add(NightBulb(mat, c, day));
  return mat;
}

/// A flat, textured toon plane lying on the ground; its texture arrives a frame or two later.
Node _groundPlane(
  double w,
  double d,
  double x,
  double y,
  double z, {
  Future<Texture2D>? map,
  String color = '#ffffff',
  double su = 1,
}) {
  final mat = Toon.create(hex(color));
  map?.then((t) => setToonTexture(mat, t));
  return mesh(groundPlane(w, d, su, 1), mat, x, y, z, false);
}

/// Polished concrete with painted bays along the back wall and along the front.
Future<Texture2D> _garageFloorTexture() {
  const w = Bldg.maxX - Bldg.minX;
  const d = Bldg.maxZ - Bldg.minZ;
  const px = 32.0; // pixels per metre
  final rnd = math.Random(7);
  return canvasTexture((w * px).round(), (d * px).round(), (g) {
    g.drawRect(const Rect.fromLTWH(0, 0, w * px, d * px), fill(linColor('#c9ccd4')));
    // A few darker blotches, so it isn't a flat slab.
    final blotch = linColor('#5a606e');
    for (var i = 0; i < 70; i++) {
      final cx = rnd.nextDouble() * w * px, cz = rnd.nextDouble() * d * px;
      final rx = 10 + rnd.nextDouble() * 30, rz = 6 + rnd.nextDouble() * 20, a = rnd.nextDouble() * 3;
      g.save();
      g.translate(cx, cz);
      g.rotate(a);
      g.drawOval(
        Rect.fromCenter(center: Offset.zero, width: rx * 2, height: rz * 2),
        fill(blotch.withValues(alpha: 0.015 + rnd.nextDouble() * 0.025)),
      );
      g.restore();
    }
    double X(double x) => (x - Bldg.minX) * px;
    double Z(double z) => (z - Bldg.minZ) * px;
    final line = fill(linColor('#fffaf0'));
    for (final (z0, z1) in [(Bldg.minZ + 0.3, Bldg.minZ + 5.8), (Bldg.maxZ - 5.8, Bldg.maxZ - 0.3)]) {
      for (var x = -16.0; x <= 16.01; x += _bay) {
        g.drawRect(Rect.fromLTWH(X(x) - 2, Z(z0), 4, (z1 - z0) * px), line);
      }
    }
    // Arrows down the aisle, pointing out to the street.
    final arrow = fill(linColor('#ffd166'));
    for (final x in [-8.0, 8.0]) {
      final cx = X(x), cz = Z(0);
      g.drawRect(Rect.fromLTWH(cx - 5, cz - 60, 10, 90), arrow);
      g.drawPath(
        Path()
          ..moveTo(cx - 22, cz + 30)
          ..lineTo(cx + 22, cz + 30)
          ..lineTo(cx, cz + 62)
          ..close(),
        arrow,
      );
    }
  });
}

/// Downstairs: the open garage under the office's floor slab (see stack.dart): concrete
/// walls at the back and on the west side, columns along the open front and east side, strip
/// lights, and a row of Lambos and a row of Ferraris. Its colliders are [garageColliders].
void buildGarage(Node group) {
  const w = Bldg.maxX - Bldg.minX;
  const d = Bldg.maxZ - Bldg.minZ;
  const cx = (Bldg.minX + Bldg.maxX) / 2;
  const cz = (Bldg.minZ + Bldg.maxZ) / 2;
  const ceiling = -slab;
  final concrete = tc('#d3d6dd');
  // The slab over it, which is the office's floor, is stack.dart's: holes go through it to the floor below.

  group.add(_groundPlane(w, d, cx, _g + 0.004, cz, map: _garageFloorTexture()));

  // The back and west walls, with a yellow band along them, and the columns and lights: all merged at the end.
  final parts = _node();
  const wallH = ceiling - _g;
  final yellow = tc('#ffd166');
  for (final (x0, x1, z0, z1) in garageWalls) {
    parts.add(mesh(box(x1 - x0, wallH, z1 - z0), concrete, (x0 + x1) / 2, _g + wallH / 2, (z0 + z1) / 2));
    parts.add(mesh(box(x1 - x0 + 0.02, 0.35, z1 - z0 + 0.02), yellow, (x0 + x1) / 2, _g + 1.1, (z0 + z1) / 2, false));
  }
  final sign = textPlane('🏎️  GARAGE', const TextOpts(bg: '#2b2d42', color: '#ffd166', size: 64, border: '#ffd166'));
  group.add(place(sign, x: 0, y: _g + 2.3, z: Bldg.minZ + wallT + 0.02, scale: 1.6));

  final colMat = tc('#e6e8ee');
  for (final (x, z) in garageColumns) {
    parts.add(mesh(box(0.5, wallH, 0.5), colMat, x, _g + wallH / 2, z));
    parts.add(mesh(box(0.52, 0.5, 0.52), yellow, x, _g + 0.25, z, false));
  }

  // Strip lights on the ceiling.
  final light = tc('#ffffff', emissive: '#fff4d6');
  for (final x in [-13.0, -4.8, 4.8, 13.0]) {
    for (final z in [-4.5, 4.5]) {
      parts.add(mesh(box(2.6, 0.07, 0.22), light, x, ceiling - 0.04, z, false));
    }
  }
  group.add(mergeByMaterial(parts));

  final lot = _node('lot');
  for (final car in parkedCars) {
    lot.add(place(supercar(car.kind, car.color), x: car.x, y: _g, z: car.z, rot: yaw(car.rotY)));
  }
  group.add(mergeByMaterial(lot));
}

Node _node([String name = '']) => Node(name: name);

Node _tree(double scale) {
  final t = _node('tree');
  t.add(mesh(cyl(0.22, 0.3, 2.2, 8), tc('#8a5a3b'), 0, 1.1, 0));
  t.add(mesh(sphere(1.6, 12, 10), tc('#5fb760'), 0, 3.2, 0));
  t.add(mesh(sphere(1.1, 12, 10), tc('#3f8f45'), 0.8, 3.9, 0.4));
  t.add(mesh(sphere(1.0, 12, 10), tc('#6fcf6a'), -0.7, 3.8, -0.3));
  t.scale = vm.Vector3.all(scale);
  return t;
}

/// A building across the street or out back: a painted block with rows of windows and a roof cap.
Node _building(double w, double h, double d, String color, NightParts night, math.Random rnd) {
  final g = _node('building');
  final floors = math.max(1, (h / 3.2).round());
  // Where the windows go across a floor (in 256ths): each column's middle half, 70 to 190 up.
  Future<Texture2D> face(int n) => canvasTexture(256, 256, (c) {
    c.drawRect(const Rect.fromLTWH(0, 0, 256, 256), fill(linColor(color)));
    final glass = fill(linColor('#bfe3ff'));
    for (var i = 0; i < n; i++) {
      c.drawRect(Rect.fromLTWH((i + 0.25) / n * 256, 70, 0.5 / n * 256, 120), glass);
    }
    final shine = fill(const Color(0xFFFFFFFF).withValues(alpha: 0.55));
    for (var i = 0; i < n; i++) {
      c.drawRect(Rect.fromLTWH((i + 0.25) / n * 256, 70, 0.12 / n * 256, 120), shine);
    }
  });
  // At night about half of them are lit: lamps, a ceiling light, the odd TV.
  Future<Texture2D> lights(int n) => canvasTexture(64, 64 * floors, (c) {
    for (var f = 0; f < floors; f++) {
      for (var i = 0; i < n; i++) {
        if (rnd.nextDouble() < 0.45) continue;
        final k = rnd.nextDouble();
        final col = k < 0.15 ? '#9ec9ff' : (rnd.nextDouble() < 0.5 ? '#ffd27a' : '#ffe6b0');
        c.drawRect(
          Rect.fromLTWH((i + 0.25) / n * 64, f * 64 + 70 / 256 * 64, 0.5 / n * 64, 120 / 256 * 64),
          fill(hex(col)),
        );
      }
    }
  });
  (Material, UnlitMaterial) walls(double span) {
    final n = math.max(1, (span / 2.6).round());
    final m = Toon.create(hex('#ffffff'));
    face(n).then((t) => setToonTexture(m, t));
    final lit = UnlitMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = vm.Vector4(1, 1, 1, 0);
    lights(n).then((t) => lit.baseColorTexture = t);
    night.windows.add(lit);
    return (m, lit);
  }

  final (sides, sidesLit) = walls(d);
  final (fronts, frontsLit) = walls(w);
  final plain = tc(color);
  g.add(place(boxFaces(w, h, d, [sides, sides, plain, plain, fronts, fronts], repeatV: floors.toDouble()), y: h / 2));
  final overlay = place(
    boxFaces(w + 0.04, h, d + 0.04, [sidesLit, sidesLit, null, null, frontsLit, frontsLit]),
    y: h / 2,
  );
  overlay.castsShadows = false;
  g.add(overlay);
  g.add(mesh(box(w + 0.4, 0.4, d + 0.4), tc('#fffaf3'), 0, h + 0.2, 0));
  return g;
}

/// A street lamp on the sidewalk at (x, z), its arm reaching out over the road toward [toward] (±1 in z).
void _streetLamp(Node parts, NightParts night, Material glass, double x, double z, double toward) {
  final ink = tc('#3d405b');
  const h = streetLampHeight;
  parts.add(mesh(cyl(0.2, 0.24, 0.5, 10), ink, x, _g + 0.25, z));
  parts.add(mesh(cyl(0.07, 0.09, h, 8), ink, x, _g + h / 2, z));
  parts.add(mesh(box(0.08, 0.08, 1.3), ink, x, _g + h - 0.05, z + toward * 0.6));
  final hz = z + toward * 1.2;
  parts.add(mesh(cyl(0.12, 0.42, 0.26, 12), ink, x, _g + h - 0.1, hz));
  parts.add(mesh(sphere(0.22, 12, 8), glass, x, _g + h - 0.3, hz, false));
  night.halos.add(Halo(at: vm.Vector3(x, _g + h - 0.34, hz), size: 2.4, color: '#ffd89a', ground: true));
  night.lamps.add(Lamp(x: x, y: _g + h - 0.6, z: hz, reach: 10, color: '#ffcf8a', power: 4, ground: true));
}

/// How far the grass and the road go, end to end: from the top floor the haze is up to 300 m off
/// (see sky_view.dart), and their ends must be further than that even at the edge of the view.
const double _reach = 1200;

/// Everything outside, down on the street: grass, the lot in front of the garage, a road with
/// sidewalks and street lamps, trees and neighbours' buildings, and in [sky] some clouds. Its
/// colliders are [streetColliders].
void buildStreet(Node group, NightParts night, Node sky) {
  group.add(mesh(groundPlane(_reach, _reach), tc('#a7d98b'), 0, _g - 0.03, 0, false));

  // The lot in front of the garage, out to the sidewalk.
  group.add(_groundPlane(60, 21 - Bldg.maxZ, 0, _g - 0.01, (Bldg.maxZ + 21) / 2, color: '#9a9ea8'));
  group.add(
    _groundPlane(
      12,
      Bldg.maxZ - Bldg.minZ + 6,
      Bldg.maxX + 6,
      _g - 0.012,
      (Bldg.minZ + Bldg.maxZ) / 2 + 1,
      color: '#9a9ea8',
    ),
  );

  // The road: asphalt, white edge lines and a dashed yellow middle.
  final road = canvasTexture(256, 128, (g) {
    g.drawRect(const Rect.fromLTWH(0, 0, 256, 128), fill(linColor('#5b606c')));
    final white = fill(linColor('#f1f1f1'));
    g.drawRect(const Rect.fromLTWH(0, 6, 256, 4), white);
    g.drawRect(const Rect.fromLTWH(0, 118, 256, 4), white);
    g.drawRect(const Rect.fromLTWH(0, 61, 150, 6), fill(linColor('#ffd166')));
  });
  group.add(
    _groundPlane(_reach, Road.maxZ - Road.minZ, 0, _g - 0.008, (Road.minZ + Road.maxZ) / 2, map: road, su: _reach / 8),
  );
  for (final (z0, z1) in [(21.0, Road.minZ), (Road.maxZ, Road.maxZ + 2)]) {
    group.add(mesh(box(_reach, 0.08, z1 - z0), tc('#e3ddd0'), 0, _g, (z0 + z1) / 2));
  }

  // Trees along the sidewalks and around the building.
  final forest = _node('forest');
  const trees = [
    (-34.0, 22.0, 1.1),
    (-22.0, 22.0, 1.0),
    (22.0, 22.0, 1.05),
    (34.0, 22.0, 0.95),
    (-40.0, 32.5, 1.1),
    (-12.0, 32.5, 1.0),
    (14.0, 32.5, 1.15),
    (42.0, 32.5, 1.0),
    (-27.0, -8.0, 1.2),
    (-29.0, 4.0, 1.0),
    (-26.0, 14.0, 0.9),
    (29.0, -6.0, 1.1),
    (30.0, 6.0, 1.25),
    (-12.0, -22.0, 1.2),
    (4.0, -24.0, 1.0),
    (18.0, -21.0, 1.1),
  ];
  for (final (x, z, s) in trees) {
    forest.add(place(_tree(s), x: x, y: _g, z: z, scale: s));
  }
  group.add(mergeByMaterial(forest));

  // Street lamps down both sidewalks, their arms out over the road.
  final lamps = _node('lamps');
  final glass = bulb(night, '#fff3d6');
  for (final (x, z, toward) in streetLamps) {
    _streetLamp(lamps, night, glass, x, z, toward);
  }
  group.add(mergeByMaterial(lamps));

  // The neighbours: across the street, and further out behind and beside the office.
  const blocks = [
    (-38.0, 45.0, 12.0, 10.0, 9.0, '#8ecae6'),
    (-22.0, 46.0, 14.0, 16.0, 10.0, '#ffb4a2'),
    (-5.0, 45.0, 12.0, 12.0, 9.0, '#b5e48c'),
    (12.0, 47.0, 16.0, 19.0, 12.0, '#cdb4db'),
    (30.0, 45.0, 12.0, 9.0, 9.0, '#ffd6a5'),
    (-20.0, -42.0, 18.0, 14.0, 10.0, '#a2d2ff'),
    (8.0, -44.0, 16.0, 20.0, 12.0, '#f4acb7'),
    (-48.0, -6.0, 10.0, 12.0, 16.0, '#ffe5b4'),
    (50.0, 4.0, 10.0, 15.0, 18.0, '#bde0fe'),
  ];
  final rnd = math.Random(11);
  for (final (x, z, w, h, d, color) in blocks) {
    // Face the office.
    final rotY = x.abs() > 40 ? (x > 0 ? -math.pi / 2 : math.pi / 2) : (z > 0 ? math.pi : 0.0);
    group.add(place(_building(w, h, d, color, night, rnd), x: x, y: _g, z: z, rot: yaw(rotY)));
  }

  // Puffy clouds, far off.
  final puffs = _node('clouds');
  const clouds = [
    (-70.0, 34.0, -60.0, 1.3),
    (-10.0, 40.0, -90.0, 1.6),
    (60.0, 36.0, -70.0, 1.2),
    (90.0, 30.0, 20.0, 1.4),
    (-95.0, 32.0, 30.0, 1.1),
    (30.0, 38.0, 95.0, 1.5),
    (-45.0, 36.0, 90.0, 1.2),
  ];
  for (final (x, y, z, s) in clouds) {
    final c = _node('cloud');
    for (final (dx, dy, r) in const [(0.0, 0.0, 5.0), (5.5, -1.0, 3.8), (-5.5, -1.2, 3.6), (2.5, 2.4, 3.4)]) {
      c.add(place(mesh(sphere(r, 14, 10), night.clouds, 0, 0, 0, false), x: dx, y: dy, scale3: vm.Vector3(1, 0.75, 1)));
    }
    puffs.add(place(c, x: x, y: y, z: z, scale: s, rot: yaw(math.atan2(-x, -z))));
  }
  sky.add(mergeByMaterial(puffs));
}
