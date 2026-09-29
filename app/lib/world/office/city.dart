// The city around the rooftop bar (a port of world/city.ts): the building's own floors going down to
// the street (as the tower looks from outside, tower.dart), a grid of streets with cars running
// along them, parks, and blocks of buildings out to the haze, most of them lower than the roof so you
// look out over them, with a skyline of towers further off. At night their windows light up, the
// street lamps come on and the cars' lights show. The building is as tall as there are floors, so
// the street is that far down (see [City.setFloors]), and the buildings round about are only as tall
// as leaves the view over them.
//
// Everything is built from a handful of shared materials (a window texture per paint, repeated a
// window at a time), merged into a few meshes, so the whole city is a few dozen draw calls.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' show Floor, roofDrop, slab, streetY, wallT;

import '../collider.dart';
import '../rooftop.dart' show RoofCity;
import '../toon.dart';
import 'geo.dart';
import 'outside.dart';
import 'parts.dart';
import 'tower.dart';

/// A block and the street beside it; streets run down x = 28 + 56k and z = 27 + 56k.
const double cityPeriod = 56;
const double cityStreetX = 28;
const double cityStreetZ = 27;

/// The road, and a sidewalk either side.
const double _road = 8;
const double _walk = 2;

/// How far out the city goes: past this the haze has it anyway.
const double cityRadius = 330;

/// One storey, and one bay of windows, in meters.
const double _storey = 3.3;
const double _bay = 2.8;

/// How far down the street was from the roof the neighbours' heights were picked for: six floors.
final double _laidOut = roofDrop(6);

/// The same numbers every time, so everyone sees the same city (mulberry32, as city.ts's rng).
double Function() cityRng(int seed) {
  var a = seed & 0xffffffff;
  int imul(int x, int y) => (x * y) & 0xffffffff;
  return () {
    a = (a + 0x6d2b79f5) & 0xffffffff;
    var t = a;
    t = imul(t ^ (t >> 15), t | 1);
    t = (t ^ (t + imul(t ^ (t >> 7), t | 61))) & 0xffffffff;
    return ((t ^ (t >> 14)) & 0xffffffff) / 4294967296;
  };
}

/// How a building's walls look: its paint, and the windows in it (glass towers are nearly all window).
class _Paint {
  const _Paint(this.wall, this.glass, this.wide, this.tall);
  final String wall, glass;

  /// The window's share of a bay across and of a storey up.
  final double wide, tall;
}

const List<_Paint> _paints = [
  _Paint('#d9a27e', '#a9d6f5', 0.5, 0.55),
  _Paint('#c96f5a', '#b8e0f7', 0.45, 0.55),
  _Paint('#e9dcc3', '#9cc9ea', 0.55, 0.6),
  _Paint('#b9c0c9', '#bfe3ff', 0.6, 0.55),
  _Paint('#a7c4d9', '#e6f4ff', 0.5, 0.6),
  _Paint('#e8b4b8', '#bfe3ff', 0.5, 0.55),
  _Paint('#f1e3b3', '#a9d6f5', 0.45, 0.5),
  // Glass towers.
  _Paint('#4f6d8a', '#7fb8d8', 0.9, 0.82),
  _Paint('#3e7c7c', '#8fd3d0', 0.9, 0.82),
];
const List<int> _glassTowers = [7, 8];

/// One bay of one storey: the wall with a window in it.
Future<Texture2D> _bayTexture(_Paint p) => canvasTexture(64, 64, (g) {
  const s = 64.0;
  g.drawRect(const Rect.fromLTWH(0, 0, s, s), fill(linColor(p.wall)));
  final w = s * p.wide, h = s * p.tall, x = (s - w) / 2, y = s * 0.18;
  g.drawRect(Rect.fromLTWH(x, y, w, h), fill(linColor(p.glass)));
  g.drawRect(Rect.fromLTWH(x + w * 0.12, y, w * 0.1, h), fill(const Color(0x73FFFFFF)));
  // A sill under it.
  g.drawRect(Rect.fromLTWH(x - 2, y + h, w + 4, 3), fill(const Color(0x1F000000)));
});

/// Which windows are lit at night: 16 x 16 bays of them, each building showing a different part.
/// Clear where they're dark, since it lies over the walls.
Future<Texture2D> _litTexture(_Paint p, int seed) {
  const n = 16, c = 16.0;
  final r = cityRng(seed);
  return canvasTexture(n * 16, n * 16, (g) {
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        if (r() < 0.5) continue;
        final k = r();
        final col = k < 0.12 ? '#9ec9ff' : (k < 0.55 ? '#ffd27a' : '#ffe6b0');
        final w = c * p.wide, h = c * p.tall;
        g.drawRect(Rect.fromLTWH(i * c + (c - w) / 2, j * c + c * 0.18, w, h), fill(hex(col)));
      }
    }
  });
}

/// Wall faces piling up for one material, to be one mesh.
class _Walls {
  final List<double> pos = [], norm = [], uv = [];
  final List<int> index = [];

  /// A quad from its bottom-left corner [a] along [u] (across) and up [h], facing [n]; [uvs] is (u0, v0, u1, v1).
  void quad(
    vm.Vector3 a,
    vm.Vector3 u,
    double h,
    vm.Vector3 n,
    (double, double, double, double) uvs, [
    double out = 0,
  ]) {
    final i = pos.length ~/ 3;
    final up = n.y == 1 ? vm.Vector3(0, 0, -h) : vm.Vector3(0, h, 0);
    final o = a + n * out;
    for (final v in [o, o + u, o + u + up, o + up]) {
      pos.addAll([v.x, v.y, v.z]);
      norm.addAll([n.x, n.y, n.z]);
    }
    final (u0, v0, u1, v1) = uvs;
    // Canvas rows run down; a storey's window sits the right way up with v flipped.
    uv.addAll([u0, -v0, u1, -v0, u1, -v1, u0, -v1]);
    // Wound to face n.
    final cr = u.cross(up);
    if (cr.dot(n) >= 0) {
      index.addAll([i, i + 1, i + 2, i, i + 2, i + 3]);
    } else {
      index.addAll([i, i + 2, i + 1, i, i + 3, i + 2]);
    }
  }

  /// The four walls of a box from y0 to y1, windows a bay across and a storey up, lit windows from
  /// (ou, ov) of the pattern ([scale] of it a bay: 1 for the walls, 1/16 for the lit overlay).
  void box(
    double cx,
    double cz,
    double w,
    double d,
    double y0,
    double y1,
    double ou,
    double ov, {
    double scale = 1,
    double out = 0,
  }) {
    final hw = w / 2, hd = d / 2;
    final floors = math.max(1, ((y1 - y0) / _storey).round());
    final h = y1 - y0;
    int across(double span) => math.max(1, (span / _bay).round());
    final cw = across(w), cd = across(d);
    (double, double, double, double) span(double u, int n) =>
        (u * scale, ov * scale, (u + n) * scale, (ov + floors) * scale);
    quad(vm.Vector3(cx - hw, y0, cz + hd), vm.Vector3(w, 0, 0), h, vm.Vector3(0, 0, 1), span(ou, cw), out);
    quad(vm.Vector3(cx + hw, y0, cz - hd), vm.Vector3(-w, 0, 0), h, vm.Vector3(0, 0, -1), span(ou + 3, cw), out);
    quad(vm.Vector3(cx + hw, y0, cz + hd), vm.Vector3(0, 0, -d), h, vm.Vector3(1, 0, 0), span(ou + 7, cd), out);
    quad(vm.Vector3(cx - hw, y0, cz - hd), vm.Vector3(0, 0, d), h, vm.Vector3(-1, 0, 0), span(ou + 11, cd), out);
  }

  /// A flat top at y.
  void top(double cx, double cz, double w, double d, double y) =>
      quad(vm.Vector3(cx - w / 2, y, cz + d / 2), vm.Vector3(w, 0, 0), d, vm.Vector3(0, 1, 0), (0, 0, 1, 1));

  bool get isEmpty => index.isEmpty;

  Geometry geometry() => MeshGeometry.fromMeshData(
    MeshData.build(
      positions: Float32List.fromList(pos),
      normals: Float32List.fromList(norm),
      texCoords: Float32List.fromList(uv),
      indices: index,
    ),
  );
}

/// The streets and blocks, a block at a time: roads, sidewalks, crossings and the lane markings.
Future<Texture2D> _groundTexture() {
  const s = 512.0, px = s / cityPeriod;
  return canvasTexture(512, 512, (g) {
    g.drawRect(const Rect.fromLTWH(0, 0, s, s), fill(linColor('#b3aea4')));
    const mid = s / 2, road = _road * px, walk = (_road + _walk * 2) * px;
    final side = fill(linColor('#d9d3c5'));
    g.drawRect(const Rect.fromLTWH(mid - walk / 2, 0, walk, s), side);
    g.drawRect(const Rect.fromLTWH(0, mid - walk / 2, s, walk), side);
    final tar = fill(linColor('#4b505c'));
    g.drawRect(const Rect.fromLTWH(mid - road / 2, 0, road, s), tar);
    g.drawRect(const Rect.fromLTWH(0, mid - road / 2, s, road), tar);
    // Dashed yellow down the middle of each road, stopping short of the crossing.
    final yellow = fill(linColor('#ffd166'));
    for (var i = 0.0; i < s; i += 24) {
      if ((i + 6 - mid).abs() < walk * 0.9) continue;
      g.drawRect(Rect.fromLTWH(mid - 1.5, i, 3, 12), yellow);
      g.drawRect(Rect.fromLTWH(i, mid - 1.5, 12, 3), yellow);
    }
    // Zebra crossings round the intersection.
    final white = fill(linColor('#f1f1f1'));
    for (var k = -road / 2 + 3; k < road / 2 - 3; k += 7) {
      for (final sg in [-1, 1]) {
        g.drawRect(Rect.fromLTWH(mid + k, mid + sg * (walk / 2 + 2) - (sg < 0 ? 16 : 0), 4, 16), white);
        g.drawRect(Rect.fromLTWH(mid + sg * (walk / 2 + 2) - (sg < 0 ? 16 : 0), mid + k, 16, 4), white);
      }
    }
  });
}

Node _tree(double Function() r) {
  final t = Node(name: 'tree');
  final s = 0.8 + r() * 0.7;
  t.add(mesh(cyl(0.25 * s, 0.32 * s, 2.4 * s, 6), tc('#8a5a3b'), 0, 1.2 * s, 0, false));
  t.add(mesh(sphere(1.9 * s, 8, 6), tc(r() < 0.5 ? '#5fb760' : '#4ea657'), 0, 3.4 * s, 0, false));
  return t;
}

/// A flat plane on the ground, facing up.
Node _flatAt(double w, double d, Material m, double x, double y, double z) =>
    mesh(groundPlane(w, d), m, x, y, z, false);

/// On a building's roof: a mast with a red light, a water tower, or a box of air conditioning.
sealed class CityRoofTop {}

class CityMast extends CityRoofTop {}

class CityTank extends CityRoofTop {
  CityTank(this.x, this.z);
  final double x, z;
}

class CityPlant extends CityRoofTop {
  CityPlant(this.x, this.z, this.w, this.d);
  final double x, z, w, d;
}

/// A building on a lot, as it was laid out round a roof six floors up. How much of that height it
/// stands depends on how far out it is ([ring]: close by, further out, or on the skyline) and on how
/// tall the office's building is (see [cityRise]).
class CityLot {
  CityLot(this.x, this.z, this.w, this.d, this.h, this.paint, this.ou, this.ov, this.ring);
  final double x, z, w, d, h;
  final int paint;

  /// Where its lit windows start in the pattern.
  final int ou, ov;
  final int ring;

  /// Tall ones step back on the way up: the top part's footprint, and how much taller it goes.
  ({double w, double d, double up})? step;
  CityRoofTop? top;
}

/// How much of its laid-out height a building in [ring] stands with the street [drop] below the
/// roof. Close by they come down with the roof, to stay under it; further out a bit less, and the
/// skyline stays the skyline. Up to six floors, where they were laid out; no taller past that.
double cityRise(int ring, double drop) {
  final k = math.min(1.0, drop / _laidOut);
  return ring == 0 ? k : (ring == 1 ? math.sqrt(k) : 1);
}

/// The lots round the office, laid out once from the same random stream every time.
List<CityLot> cityLots([void Function(double x, double z, double inner, double Function() r)? park]) {
  final r = cityRng(20260927);
  final lots = <CityLot>[];
  const inner = cityPeriod - _road - _walk * 2;
  final n = (cityRadius / cityPeriod).ceil() + 1;
  for (var i = -n; i <= n; i++) {
    for (var j = -n; j <= n; j++) {
      final bx = cityStreetX - cityPeriod / 2 + i * cityPeriod, bz = cityStreetZ - cityPeriod / 2 + j * cityPeriod;
      final dist = math.sqrt(bx * bx + bz * bz);
      if (dist > cityRadius) continue;
      // The block the office stands on: a plaza round it.
      if (i == 0 && j == 0) continue;
      // Now and then a park, with trees.
      if (r() < 0.1 && dist > 60) {
        if (park != null) {
          park(bx, bz, inner, r);
        } else {
          for (var k = 0; k < 28; k++) {
            r();
          }
        }
        continue;
      }
      // The block split into lots: one big one, two halves or four quarters.
      final split = r();
      final plots = <(double, double, double, double)>[];
      const gap = 2.0;
      if (split < 0.25) {
        plots.add((bx, bz, inner, inner));
      } else if (split < 0.6) {
        const w = (inner - gap) / 2;
        final alongX = r() < 0.5;
        for (final s in [-1, 1]) {
          plots.add(alongX ? (bx + s * (w + gap) / 2, bz, w, inner) : (bx, bz + s * (w + gap) / 2, inner, w));
        }
      } else {
        const w = (inner - gap) / 2;
        for (final sx in [-1, 1]) {
          for (final sz in [-1, 1]) {
            plots.add((bx + sx * (w + gap) / 2, bz + sz * (w + gap) / 2, w, w));
          }
        }
      }
      // Lower than the roof round about, so you see out over them; taller further out, and tallest
      // downtown, off to the north-east, where the skyline is.
      final downtown = math.max(0, 1 - math.sqrt(math.pow(bx - 210, 2) + math.pow(bz + 220, 2)) / 150);
      for (final (lx, lz, lw, ld) in plots) {
        final back = 1 + r() * 3;
        final w = lw - back * 2, d = ld - back * 2;
        if (w < 6 || d < 6) continue;
        double h;
        if (dist < 100) {
          h = 9 + r() * 24 + (r() < 0.1 ? 8 : 0);
        } else if (dist < 190) {
          h = r() < 0.1 ? 50 + r() * 40 : 12 + r() * 28;
        } else {
          h = r() < 0.2 ? 65 + r() * 95 : 20 + r() * 30;
        }
        h *= 1 + downtown * 1.3;
        final glassy = h > 70 && r() < 0.6;
        final paint = glassy ? _glassTowers[(r() * _glassTowers.length).floor()] : (r() * 7).floor();
        final lot = CityLot(
          lx,
          lz,
          w,
          d,
          h,
          paint,
          (r() * 16).floor(),
          (r() * 16).floor(),
          dist < 100 ? 0 : (dist < 190 ? 1 : 2),
        );
        var tall = h, tw = w, td = d;
        // Tall ones step back once on the way up.
        if (h > 55 && r() < 0.6) {
          tw = w * (0.55 + r() * 0.25);
          td = d * (0.55 + r() * 0.25);
          lot.step = (w: tw, d: td, up: 12 + r() * h * 0.5);
          tall += lot.step!.up;
        }
        // On the roof: a water tower, a box of air conditioning, or a mast with a red light.
        final what = r();
        if (tall > 90) {
          lot.top = CityMast();
        } else if (what < 0.3) {
          lot.top = CityTank(lx + (r() - 0.5) * tw * 0.4, lz + (r() - 0.5) * td * 0.4);
        } else if (what < 0.65) {
          final pw = 3 + r() * 3, pd = 2 + r() * 2;
          lot.top = CityPlant(lx + (r() - 0.5) * tw * 0.4, lz + (r() - 0.5) * td * 0.4, pw, pd);
        }
        lots.add(lot);
      }
    }
  }
  return lots;
}

class _Car {
  _Car(this.alongX, this.lane, this.dir, this.at, this.speed);

  /// Along x (true) or z.
  final bool alongX;

  /// The lane's line across the street, and which way it drives (±1).
  final double lane;
  final int dir;
  double at;
  final double speed;
}

/// The city round the roof.
class City implements RoofCity {
  City._(this._night) {
    _build();
  }

  final NightParts _night;
  @override
  final Node group = Node(name: 'city');

  /// Everything down on the street, which is as far below the roof as the building is tall.
  final Node _street = Node(name: 'street');
  late final Tower _building;
  late final List<CityLot> _lots;
  final Map<int, (Material, UnlitMaterial)> _paintMats = {};
  final List<Node> _raised = [];
  late final UnlitMaterial _lampMat, _beaconMat, _headMat, _tailMat;
  late final Node _lamps;
  Node? _beacons;
  final List<_Car> _cars = [];
  late final InstancedMesh _carMesh, _heads, _tails;
  int _floorsNow = 0;
  double _riseNow = -1;

  void _build() {
    group.add(_street);
    // The ground: every block and street, repeated out to the haze.
    const size = cityPeriod * 24;
    final groundMat = Toon.create(hex('#ffffff'));
    _groundTexture().then((t) => setToonTexture(groundMat, t));
    // Line the texture up with the streets: a road down its middle falls on x = cityStreetX, z = cityStreetZ.
    const h = size / 2;
    double u(double x) => (x - cityStreetX) / cityPeriod + 0.5;
    double v(double z) => (z - cityStreetZ) / cityPeriod + 0.5;
    _street.add(
      Node(
        name: 'ground',
        mesh: Mesh(
          MeshGeometry.fromMeshData(
            MeshData.build(
              positions: Float32List.fromList([-h, 0, -h, h, 0, -h, h, 0, h, -h, 0, h]),
              normals: Float32List.fromList([0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0]),
              texCoords: Float32List.fromList([u(-h), v(-h), u(h), v(-h), u(h), v(h), u(-h), v(h)]),
              // Facing up: counter-clockwise seen from above in three's frame.
              indices: [0, 2, 1, 0, 3, 2],
            ),
          ),
          groundMat,
        ),
      ),
    );

    // The blocks: parks now and then, and lots with a building on each, laid out once. How tall the
    // buildings stand depends on the roof (see _raise).
    final parks = Node(name: 'parks');
    final grass = tc('#8fcf7a');
    _lots = cityLots((bx, bz, inner, r) {
      parks.add(_flatAt(inner, inner, grass, bx, 0.03, bz));
      for (var k = 0; k < 7; k++) {
        parks.add(place(_tree(r), x: bx + (r() - 0.5) * (inner - 6), z: bz + (r() - 0.5) * (inner - 6)));
      }
    });
    final r = cityRng(7);

    // The office's own building, a floor per project, from the street up to the roof, and the open
    // garage at the bottom: walled at the back and on the west side, columns along the other two.
    _building = buildTower(<Collider>[], _night);
    group.add(_building.group);
    const bx0 = Floor.minX - wallT, bx1 = Floor.maxX + wallT, bz0 = Floor.minZ - wallT, bz1 = Floor.maxZ + wallT;
    final garage = Node(name: 'garage');
    const garageH = -streetY - slab;
    final concrete = tc('#d3d6dd'), column = tc('#e6e8ee');
    garage.add(mesh(box(bx1 - bx0, garageH, wallT), concrete, (bx0 + bx1) / 2, garageH / 2, bz0 + wallT / 2, false));
    garage.add(mesh(box(wallT, garageH, bz1 - bz0), concrete, bx0 + wallT / 2, garageH / 2, (bz0 + bz1) / 2, false));
    for (final x in [bx1 - 0.25, -9.6, 0.0, 9.6]) {
      garage.add(mesh(box(0.5, garageH, 0.5), column, x, garageH / 2, bz1 - 0.25, false));
    }
    for (final z in [-6.5, 6.5, bz0 + 0.25]) {
      garage.add(mesh(box(0.5, garageH, 0.5), column, bx1 - 0.25, garageH / 2, z, false));
    }
    garage.add(_flatAt(bx1 - bx0, bz1 - bz0, tc('#9a9ea8'), (bx0 + bx1) / 2, 0.03, (bz0 + bz1) / 2));
    _street.add(mergeByMaterial(garage));
    // Its plaza, with a few trees in front.
    const inner = cityPeriod - _road - _walk * 2;
    parks.add(_flatAt(inner, inner, tc('#cfc8b8'), cityStreetX - cityPeriod / 2, 0.02, cityStreetZ - cityPeriod / 2));
    for (final (x, z) in const [
      (-16.0, 18.0),
      (-6.0, 18.0),
      (6.0, 18.0),
      (16.0, 18.0),
      (-20.0, -18.0),
      (20.0, -18.0),
    ]) {
      parks.add(place(_tree(r), x: x, z: z));
    }
    _street.add(mergeByMaterial(parks));

    // Street lamps down both sides of every street, and red lights blinking on the masts: little
    // glowing balls, only there at night.
    _lampMat = UnlitMaterial()..baseColorFactor = linear(hex('#ffcf8a'));
    _beaconMat = UnlitMaterial()..baseColorFactor = linear(hex('#ff3b30'));
    final lamps = Node(name: 'lamps');
    final n = (cityRadius / cityPeriod).ceil() + 1;
    final bulbGeo = sphere(0.45, 6, 4);
    for (var k = -n; k <= n; k++) {
      for (var a = -cityRadius; a <= cityRadius; a += 28) {
        for (final s in [-1, 1]) {
          final off = s * (_road / 2 + 0.6);
          final sx = cityStreetX + k * cityPeriod, sz = cityStreetZ + k * cityPeriod;
          if (math.sqrt(sx * sx + a * a) < cityRadius) lamps.add(mesh(bulbGeo, _lampMat, sx + off, 5, a, false));
          if (math.sqrt(a * a + sz * sz) < cityRadius) lamps.add(mesh(bulbGeo, _lampMat, a, 5, sz + off, false));
        }
      }
    }
    _lamps = mergeByMaterial(lamps)..visible = false;
    _street.add(_lamps);

    // Cars, up and down the streets round the office's block.
    const lanes = [
      (true, cityStreetZ),
      (true, cityStreetZ - cityPeriod),
      (false, cityStreetX),
      (false, cityStreetX - cityPeriod),
      (true, cityStreetZ + cityPeriod),
      (false, cityStreetX + cityPeriod),
    ];
    for (final (alongX, line) in lanes) {
      for (var k = 0; k < 7; k++) {
        final dir = k.isOdd ? 1 : -1;
        _cars.add(
          _Car(
            alongX,
            line + dir * (_road / 4) * (alongX ? 1 : -1),
            dir,
            -cityRadius + r() * cityRadius * 2,
            9 + r() * 6,
          ),
        );
      }
    }
    final body = Node()
      ..add(mesh(box(4.2, 1.05, 1.9), tc('#ffffff'), 0, 0.9, 0, false))
      ..add(mesh(box(2.2, 0.7, 1.7), tc('#ffffff'), -0.3, 1.75, 0, false));
    final carGeo = mergeByMaterial(body).children.first.mesh!.primitives.first.geometry;
    _carMesh = InstancedMesh(geometry: carGeo, material: Toon.create(hex('#ffffff')));
    _headMat = UnlitMaterial()..baseColorFactor = linear(hex('#fff6d0'));
    _tailMat = UnlitMaterial()..baseColorFactor = linear(hex('#ff2d2d'));
    _heads = InstancedMesh(
      geometry: transformed(box(0.12, 0.3, 1.6), vm.Matrix4.translationValues(2.12, 0.95, 0)),
      material: _headMat,
    );
    _tails = InstancedMesh(
      geometry: transformed(box(0.12, 0.25, 1.6), vm.Matrix4.translationValues(-2.12, 0.95, 0)),
      material: _tailMat,
    );
    const colors = ['#ef476f', '#ffd166', '#06d6a0', '#118ab2', '#f4f1de', '#3d405b', '#e07a5f', '#8ecae6'];
    for (var i = 0; i < _cars.length; i++) {
      _carMesh.addInstance(vm.Matrix4.identity(), color: linear(hex(colors[(r() * colors.length).floor()])));
      _heads.addInstance(vm.Matrix4.identity());
      _tails.addInstance(vm.Matrix4.identity());
    }
    for (final (name, m) in [('cars', _carMesh), ('heads', _heads), ('tails', _tails)]) {
      _street.add(
        Node(name: name)
          ..addComponent(InstancedMeshComponent(m))
          ..castsShadows = false
          ..frustumCulled = false,
      );
    }
    _moveCars(0);

    // Clouds, drifting past at about the height of the towers.
    final sky = Node(name: 'city-clouds');
    for (var k = 0; k < 9; k++) {
      final a = k / 9 * math.pi * 2 + r();
      final dist = 220 + r() * 120;
      final c = Node(name: 'cloud');
      for (final (dx, dy, rad) in const [(0.0, 0.0, 9.0), (10.0, -2.0, 7.0), (-10.0, -2.0, 6.5), (4.0, 4.0, 6.0)]) {
        c.add(
          place(mesh(sphere(rad, 12, 9), _night.clouds, 0, 0, 0, false), x: dx, y: dy, scale3: vm.Vector3(1, 0.7, 1)),
        );
      }
      final x = math.cos(a) * dist, z = math.sin(a) * dist;
      sky.add(place(c, x: x, y: 40 + r() * 50, z: z, rot: yaw(math.atan2(-x, -z))));
    }
    group.add(mergeByMaterial(sky));
  }

  (Material, UnlitMaterial) _paintOf(int i) => _paintMats[i] ??= () {
    final p = _paints[i];
    final wall = Toon.create(hex('#ffffff'));
    _bayTexture(p).then((t) => setToonTexture(wall, t));
    final lit = UnlitMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = vm.Vector4(1, 1, 1, 0);
    _litTexture(p, i + 1).then((t) => lit.baseColorTexture = t);
    _night.windows.add(lit);
    return (wall, lit);
  }();

  /// Puts up the buildings, each as tall as [cityRise] says with the street [drop] below the roof.
  void _raise(double drop) {
    for (final n in _raised) {
      n.detach();
    }
    _raised.clear();
    _beacons?.detach();
    final walls = <int, _Walls>{}, lit = <int, _Walls>{};
    final tops = _Walls();
    final extras = Node(name: 'roof-extras');
    final beacons = Node(name: 'beacons');
    final beaconGeo = sphere(0.9, 6, 4);
    for (final lot in _lots) {
      final k = cityRise(lot.ring, drop);
      final bucket = walls[lot.paint] ??= _Walls();
      final glow = lit[lot.paint] ??= _Walls();
      var topY = lot.h * k;
      bucket.box(lot.x, lot.z, lot.w, lot.d, 0, topY, lot.ou.toDouble(), lot.ov.toDouble());
      glow.box(lot.x, lot.z, lot.w, lot.d, 0, topY, lot.ou.toDouble(), lot.ov.toDouble(), scale: 1 / 16, out: 0.06);
      var tw = lot.w, td = lot.d;
      final step = lot.step;
      if (step != null) {
        tops.top(lot.x, lot.z, lot.w, lot.d, topY);
        tw = step.w;
        td = step.d;
        final y1 = topY + step.up * k;
        bucket.box(lot.x, lot.z, tw, td, topY, y1, lot.ou + 5.0, lot.ov + 3.0);
        glow.box(lot.x, lot.z, tw, td, topY, y1, lot.ou + 5.0, lot.ov + 3.0, scale: 1 / 16, out: 0.06);
        topY = y1;
      }
      tops.top(lot.x, lot.z, tw, td, topY);
      switch (lot.top) {
        case CityMast():
          extras.add(mesh(cyl(0.2, 0.35, 12, 6), tc('#8d99ae'), lot.x, topY + 6, lot.z, false));
          beacons.add(mesh(beaconGeo, _beaconMat, lot.x, topY + 12.3, lot.z, false));
        case CityTank(:final x, :final z):
          final wt = Node(name: 'tank');
          for (final (sx, sz) in const [(-1, -1), (1, -1), (-1, 1), (1, 1)]) {
            wt.add(mesh(cyl(0.12, 0.12, 2.4, 5), tc('#5b3a29'), sx * 1.1, 1.2, sz * 1.1, false));
          }
          wt.add(mesh(cyl(1.6, 1.6, 3.2, 12), tc('#9c6b4a'), 0, 4, 0, false));
          wt.add(mesh(cone(1.8, 1.3, 12), tc('#6b4a35'), 0, 6.25, 0, false));
          extras.add(place(wt, x: x, y: topY, z: z));
        case CityPlant(:final x, :final z, :final w, :final d):
          extras.add(
            place(
              mesh(box(1, 1.6, 1), tc('#c9ccd4'), 0, 0, 0, false),
              x: x,
              y: topY + 0.8,
              z: z,
              scale3: vm.Vector3(w, 1, d),
            ),
          );
        case null:
          break;
      }
    }
    for (final e in walls.entries) {
      final (wall, glass) = _paintOf(e.key);
      _raised.add(Node(name: 'walls', mesh: Mesh(e.value.geometry(), wall))..castsShadows = false);
      _raised.add(Node(name: 'lit', mesh: Mesh(lit[e.key]!.geometry(), glass))..castsShadows = false);
    }
    _raised.add(Node(name: 'roofs', mesh: Mesh(tops.geometry(), tc('#a19d97')))..castsShadows = false);
    _raised.add(mergeByMaterial(extras));
    for (final n in _raised) {
      _street.add(n);
    }
    _beacons = beacons.children.isEmpty ? null : mergeByMaterial(beacons);
    if (_beacons != null) _street.add(_beacons!);
  }

  void _moveCars(double dt) {
    for (var i = 0; i < _cars.length; i++) {
      final c = _cars[i];
      c.at += c.dir * c.speed * dt;
      if (c.at > cityRadius) c.at -= cityRadius * 2;
      if (c.at < -cityRadius) c.at += cityRadius * 2;
      final at = c.alongX ? vm.Vector3(c.at, 0, c.lane) : vm.Vector3(c.lane, 0, c.at);
      // The car's nose is +x: turned to face the way it's going.
      final yawA = c.alongX ? (c.dir > 0 ? 0.0 : math.pi) : (c.dir > 0 ? -math.pi / 2 : math.pi / 2);
      final m = vm.Matrix4.compose(at, vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), yawA), vm.Vector3.all(1));
      _carMesh.setInstanceTransform(i, m);
      _heads.setInstanceTransform(i, m);
      _tails.setInstanceTransform(i, m);
    }
  }

  /// The building has [floors] floors under the roof: the street goes as far down as that is tall,
  /// and the buildings nearby come down to stay under the roof.
  @override
  void setFloors(int floors) {
    floors = math.max(1, floors);
    if (floors == _floorsNow) return;
    _floorsNow = floors;
    final drop = roofDrop(floors);
    _street.position = vm.Vector3(0, -drop, 0);
    _building.set(floors, floors);
    // The buildings only change height up to six floors (see cityRise).
    final k = math.min(1.0, drop / _laidOut);
    if (k != _riseNow) {
      _riseNow = k;
      _raise(drop);
    }
  }

  /// The cars along the streets, the blinking lights on the masts: [dark] is how dark it is (0–1).
  @override
  void update(double t, double dt, double dark) {
    _moveCars(dt);
    _lamps.visible = dark > 0.02;
    final head = 0.75 + 0.25 * dark;
    final c = linear(hex('#fff6d0'));
    _headMat.baseColorFactor = vm.Vector4(c.x * head, c.y * head, c.z * head, 1);
    // The masts' lights blink, a second on and a second off.
    _beacons?.visible = math.sin(t * math.pi) > 0;
  }
}

/// The city round the roof; call [City.setFloors] before showing it.
City buildCity(NightParts night) => City._(night);
