// What every part of the scenic loop builds with (world/scenic/kit.ts): lines and strips laid along
// the road, where things are round it, and the kit each part builds into (see makeKit).
//
// Unlike the TS, which builds three.js meshes straight away, the loop is laid out here on the CPU
// alone: every piece is vertex data and what it's to look like (a [Coat]), in [Clump]s placed like
// groups. scenic.dart then merges them a square of the map at a time and uploads them. So the layout
// (where every tree is, and what you bump into) can be worked out, and tested, without a GPU.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' show MeshData;
// The engine's own primitives, as vertex data alone (its geometries upload them as they're made).
// ignore: implementation_imports
import 'package:flutter_scene/src/geometry/primitives.dart'
    show buildCuboidArrays, buildCylinderArrays, buildIcosphereArrays;
import 'package:office_shared/layout.dart' show streetY;
import 'package:office_shared/rng.dart';
import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../office/geo.dart' show Shape2, triangulate;
import '../office/outside.dart' show Halo;
import '../text.dart' show TextOpts;

/// The street's level, which everything along the loop stands on.
const double G = streetY;

// ---- What things look like ----------------------------------------------------------------------

/// The canvases the loop's flat things are painted with (see scenic.dart's _paint).
enum Painted { asphalt, checks, wheat, greens, creek, lake, sea }

/// What a piece is to look like.
enum CoatKind {
  /// A plain toon colour: merged with every other plain piece near it into one mesh, the colours in
  /// its vertices (mergeByColor).
  plain,

  /// A bulb that glows [Coat.day] much by day and fully at night (outside.dart's bulb).
  bulb,

  /// A toon colour that always glows [Coat.emissive] a little (a reflector).
  glow,

  /// Something flat on the ground, maybe painted ([Coat.canvas]) or see-through ([Coat.opacity]).
  flat,

  /// Unlit, lit by its own lamps whatever the sun's doing (the road through the tunnel).
  dim,

  /// Unlit, its colours in its vertices, seen from both sides (the tunnel's lining).
  lining,

  /// Light you only see at night: see-through, its alpha in its vertices (the lighthouse's beam).
  beam,
}

class Coat {
  const Coat._(this.kind, this.color, {this.canvas, this.opacity = 1, this.day = 0, this.emissive});

  /// A plain toon colour (toon() in the TS).
  const Coat.plain(String color) : this._(CoatKind.plain, color);
  const Coat.bulb(String color, [double day = 0]) : this._(CoatKind.bulb, color, day: day);
  const Coat.glow(String color, String emissive) : this._(CoatKind.glow, color, emissive: emissive);
  const Coat.flat(String color, {Painted? canvas, double opacity = 1})
    : this._(CoatKind.flat, color, canvas: canvas, opacity: opacity);
  const Coat.dim(String color, {Painted? canvas}) : this._(CoatKind.dim, color, canvas: canvas);
  static const Coat lining = Coat._(CoatKind.lining, '#ffffff');
  const Coat.beam(String color) : this._(CoatKind.beam, color);

  final CoatKind kind;
  final String color;
  final Painted? canvas;
  final double opacity;
  final double day;
  final String? emissive;

  @override
  bool operator ==(Object other) =>
      other is Coat &&
      other.kind == kind &&
      other.color == color &&
      other.canvas == canvas &&
      other.opacity == opacity &&
      other.day == day &&
      other.emissive == emissive;

  @override
  int get hashCode => Object.hash(kind, color, canvas, opacity, day, emissive);
}

/// One piece of a clump: its vertices (in the clump's frame, once [xf] has placed them), and its look.
class Piece {
  Piece(this.data, this.coat, this.xf, this.shadow);
  final MeshData data;
  final Coat coat;
  final vm.Matrix4 xf;
  final bool shadow;
}

/// A group of pieces, placed and turned as one (a THREE.Group of meshes).
class Clump {
  Clump({double x = 0, double y = 0, double z = 0}) : position = vm.Vector3(x, y, z);

  final List<Piece> pieces = [];
  vm.Vector3 position;
  vm.Quaternion rotation = vm.Quaternion.identity();
  vm.Vector3 scale = vm.Vector3.all(1);

  /// Where the clump puts its pieces.
  vm.Matrix4 get xf => vm.Matrix4.compose(position, rotation, scale);

  /// A piece at (x, y, z), turned by [rot] (and scaled by [scale]).
  void add(
    MeshData data,
    Coat coat, {
    double x = 0,
    double y = 0,
    double z = 0,
    vm.Quaternion? rot,
    vm.Vector3? scale,
    bool shadow = true,
  }) => pieces.add(
    Piece(
      data,
      coat,
      vm.Matrix4.compose(vm.Vector3(x, y, z), rot ?? vm.Quaternion.identity(), scale ?? vm.Vector3.all(1)),
      shadow,
    ),
  );

  /// Another clump's pieces, where it puts them (a group added to a group).
  void addClump(Clump c) {
    final m = c.xf;
    for (final p in c.pieces) {
      pieces.add(Piece(p.data, p.coat, m * p.xf as vm.Matrix4, p.shadow));
    }
  }

  /// Turned about y (three's rotation.y = a).
  void turn(double a) => rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), a);
}

// ---- Shapes, as vertex data (three's geometries) -------------------------------------------------

Float32List _f32(List<double> v) => Float32List.fromList(v);

final Map<String, MeshData> _shapes = {};

MeshData _once(String key, MeshData Function() make) => _shapes[key] ??= make();

/// three's BoxGeometry.
MeshData box(double w, double h, double d) => _once('box $w $h $d', () {
  final a = buildCuboidArrays(vm.Vector3(w, h, d));
  return MeshData.build(positions: a.positions, normals: a.normals, indices: a.indices);
});

/// three's CylinderGeometry(radiusTop, radiusBottom, height, radialSegments, 1, openEnded).
MeshData cyl(double rt, double rb, double h, [int seg = 8, bool open = false]) =>
    _once('cyl $rt $rb $h $seg $open', () {
      final a = buildCylinderArrays(
        bottomRadius: rb,
        topRadius: rt,
        height: h,
        radialSegments: seg,
        heightSegments: 1,
        bottomCap: !open,
        topCap: !open,
      );
      return MeshData.build(positions: a.positions, normals: a.normals, indices: a.indices);
    });

/// three's ConeGeometry(radius, height, radialSegments, 1, openEnded): apex up.
MeshData cone(double r, double h, [int seg = 8, bool open = false]) => cyl(0, r, h, seg, open);

/// three's SphereGeometry(radius, widthSegments, heightSegments, 0, 2π, 0, [theta]): down from the top
/// [theta] of the way round (π the whole sphere, π/2 a dome).
MeshData sphere(double r, [int w = 12, int h = 10, double theta = math.pi]) => _once('sphere $r $w $h $theta', () {
  final pos = <double>[], nor = <double>[];
  final idx = <int>[];
  for (var j = 0; j <= h; j++) {
    final lat = theta * j / h;
    for (var i = 0; i <= w; i++) {
      final lon = 2 * math.pi * i / w;
      final nx = math.sin(lat) * math.cos(lon), ny = math.cos(lat), nz = math.sin(lat) * math.sin(lon);
      pos.addAll([r * nx, r * ny, r * nz]);
      nor.addAll([nx, ny, nz]);
    }
  }
  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      final a = j * (w + 1) + i, b = a + 1, c = a + w + 1, d = c + 1;
      idx.addAll([a, b, c, b, d, c]);
    }
  }
  return MeshData.build(positions: _f32(pos), normals: _f32(nor), indices: idx);
});

/// Triangles alone, each face flat (three's computeVertexNormals on an unindexed geometry).
MeshData faceted(List<double> positions) => MeshData.build(positions: _f32(positions));

/// Triangles alone, each vertex its own colour (linear RGBA, four floats each).
MeshData coloured(List<double> positions, List<double> colors) =>
    MeshData.build(positions: _f32(positions), colors: _f32(colors));

/// three's IcosahedronGeometry(radius, detail): faceted.
List<double> icosahedron(double r, int detail) {
  final a = buildIcosphereArrays(radius: r, subdivisions: detail);
  final out = <double>[];
  for (final i in a.indices) {
    out.addAll([a.positions[i * 3], a.positions[i * 3 + 1], a.positions[i * 3 + 2]]);
  }
  return out;
}

MeshData ico(double r, int detail) => _once('ico $r $detail', () => faceted(icosahedron(r, detail)));

/// three's TorusGeometry(radius, tube, radialSegments, tubularSegments, arc): a ring in XY, the arc
/// running counter-clockwise from +x.
MeshData torus(double radius, double tube, int radial, int tubular, double arc) =>
    _once('torus $radius $tube $radial $tubular $arc', () {
      final pos = <double>[], nor = <double>[];
      final idx = <int>[];
      for (var j = 0; j <= radial; j++) {
        for (var i = 0; i <= tubular; i++) {
          final u = i / tubular * arc;
          final v = j / radial * math.pi * 2;
          final cx = radius * math.cos(u), cy = radius * math.sin(u);
          final x = (radius + tube * math.cos(v)) * math.cos(u);
          final y = (radius + tube * math.cos(v)) * math.sin(u);
          final z = tube * math.sin(v);
          pos.addAll([x, y, z]);
          final n = vm.Vector3(x - cx, y - cy, z)..normalize();
          nor.addAll([n.x, n.y, n.z]);
        }
      }
      for (var j = 1; j <= radial; j++) {
        for (var i = 1; i <= tubular; i++) {
          final a = (tubular + 1) * j + i - 1;
          final b = (tubular + 1) * (j - 1) + i - 1;
          final c = (tubular + 1) * (j - 1) + i;
          final d = (tubular + 1) * j + i;
          idx.addAll([a, b, d, b, c, d]);
        }
      }
      return MeshData.build(positions: _f32(pos), normals: _f32(nor), indices: idx);
    });

/// A shape's triangles in XY facing +z (three's ShapeGeometry), or pushed out along +z to [depth]
/// (ExtrudeGeometry, no bevel), faceted. Flat, it's seen from the front alone unless [both].
MeshData shapeMesh(Shape2 s, {double depth = 0, bool both = false}) {
  final outer = s.points;
  final tris = triangulate(outer, const []);
  final p = <double>[];
  void v(vm.Vector2 a, double z) => p.addAll([a.x, a.y, z]);
  for (var i = 0; i < tris.length; i += 3) {
    final a = outer[tris[i]], b = outer[tris[i + 1]], c = outer[tris[i + 2]];
    v(a, depth);
    v(b, depth);
    v(c, depth);
    if (depth > 0 || both) {
      v(a, 0);
      v(c, 0);
      v(b, 0);
    }
  }
  if (depth > 0) {
    for (var i = 0; i < outer.length; i++) {
      final a = outer[i], b = outer[(i + 1) % outer.length];
      v(a, 0);
      v(b, 0);
      v(b, depth);
      v(a, 0);
      v(b, depth);
      v(a, depth);
    }
  }
  return faceted(p);
}

/// [d] moved by [m] (three's geometry.rotateX / translate…).
MeshData moved(MeshData d, vm.Matrix4 m) => d.transformed(m);

vm.Quaternion yawQ(double a) => vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), a);

/// three's Euler (XYZ order) as a quaternion.
vm.Quaternion eulerQ(double x, [double y = 0, double z = 0]) =>
    vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), x) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), y) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), z);

// ---- Lines along the road ----------------------------------------------------------------------

/// A point along a line, and the way it goes there (see RoadPoint).
class Along {
  const Along(this.x, this.z, this.tx, this.tz, [this.d = 0]);
  final double x, z, tx, tz;

  /// Meters round the loop, where it's on it.
  final double d;
}

Along alongOf(RoadPoint p) => Along(p.x, p.z, p.tx, p.tz, p.d);

typedef XZ = ({double x, double z});

/// A line's points with the way it goes at each.
List<Along> withTangents(List<XZ> pts) => [
  for (var i = 0; i < pts.length; i++)
    () {
      final a = pts[math.max(0, i - 1)], b = pts[math.min(pts.length - 1, i + 1)];
      var len = math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.z - a.z, 2));
      if (len == 0) len = 1;
      return Along(pts[i].x, pts[i].z, (b.x - a.x) / len, (b.z - a.z) / len);
    }(),
];

/// A smooth line through [knots], [per] points between each two (uniform Catmull–Rom).
List<XZ> smooth(List<(double, double)> knots, int per) {
  final out = <XZ>[];
  final n = knots.length;
  for (var i = 0; i < n - 1; i++) {
    final k = [
      for (final j in [i - 1, i, i + 1, i + 2]) knots[j.clamp(0, n - 1)],
    ];
    for (var s = 0; s < per; s++) {
      final t = s / per, t2 = t * t, t3 = t2 * t;
      double f(double a, double b, double c, double d) =>
          0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3);
      out.add((x: f(k[0].$1, k[1].$1, k[2].$1, k[3].$1), z: f(k[0].$2, k[1].$2, k[2].$2, k[3].$2)));
    }
  }
  out.add((x: knots[n - 1].$1, z: knots[n - 1].$2));
  return out;
}

/// A strip along [pts], from [right] to [left] meters off its middle (+ is its left, going along), at
/// height [y] (or [ys], one for each side: 'l' or 'r'), with u running along it and v across (1 on the left).
MeshData strip(
  List<Along> pts,
  double right,
  double left,
  double y,
  double Function(int i) u, {
  double Function(int i, String side)? ys,
}) {
  final pos = <double>[], uv = <double>[], nor = <double>[];
  final idx = <int>[];
  double at(int i, String side) => ys == null ? y : ys(i, side);
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i];
    // Left of the way along is (tz, -tx).
    pos.addAll([p.x + p.tz * left, at(i, 'l'), p.z - p.tx * left, p.x + p.tz * right, at(i, 'r'), p.z - p.tx * right]);
    uv.addAll([u(i), 1, u(i), 0]);
    nor.addAll([0, 1, 0, 0, 1, 0]);
    if (i > 0) {
      final l0 = (i - 1) * 2;
      idx.addAll([l0, l0 + 1, l0 + 2, l0 + 1, l0 + 3, l0 + 2]);
    }
  }
  return MeshData.build(
    positions: _f32(pos),
    normals: ys == null ? _f32(nor) : null,
    texCoords: _f32(uv),
    indices: idx,
  );
}

/// A w x d plane lying flat at the origin, facing up, its UVs [su] x [sv] (a texture's repeat).
MeshData flatPlane(double w, double d, [double su = 1, double sv = 1]) {
  final x = w / 2, z = d / 2;
  return MeshData.build(
    positions: _f32([-x, 0, z, x, 0, z, x, 0, -z, -x, 0, -z]),
    normals: _f32([0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0]),
    texCoords: _f32([0, sv, su, sv, su, 0, 0, 0]),
    indices: [0, 1, 2, 0, 2, 3],
  );
}

/// An ellipse lying flat at the origin, [rx] by [rz] (a ring, inside [irx] by [irz]: none, a whole
/// disc), its UVs [su] x [sv] across it.
MeshData flatEllipse(
  double rx,
  double rz, {
  double irx = 0,
  double irz = 0,
  int seg = 48,
  double su = 1,
  double sv = 1,
}) {
  final pos = <double>[], uv = <double>[], nor = <double>[];
  final idx = <int>[];
  for (var i = 0; i <= seg; i++) {
    final a = i / seg * math.pi * 2;
    final c = math.cos(a), s = math.sin(a);
    for (final (ax, az) in [(rx, rz), (irx, irz)]) {
      // three's CircleGeometry lies in XY; turned flat (rotation.x = -π/2), its y is -z.
      pos.addAll([c * ax, 0, -s * az]);
      final kx = ax / rx, kz = az / rz;
      uv.addAll([(c * kx * 0.5 + 0.5) * su, (1 - (s * kz * 0.5 + 0.5)) * sv]);
      nor.addAll([0, 1, 0]);
    }
  }
  for (var i = 0; i < seg; i++) {
    final o0 = i * 2, i0 = o0 + 1, o1 = o0 + 2, i1 = o0 + 3;
    idx.addAll([o0, o1, i1, o0, i1, i0]);
  }
  return MeshData.build(positions: _f32(pos), normals: _f32(nor), texCoords: _f32(uv), indices: idx);
}

/// A point [off] meters to the left of the loop's middle at loop[i] (right, if negative).
XZ beside(int i, double off) {
  final p = loop[i.clamp(0, loop.length - 1)];
  return (x: p.x + p.tz * off, z: p.z - p.tx * off);
}

/// The loop's point nearest [d] meters round it.
int indexAt(double d) => ((d / loopLength) * (loop.length - 1)).round().clamp(0, loop.length - 1);

/// Where each bit of the loop starts and ends, meters round it.
List<({double from, double to})> stretch(ScenicPlace place) {
  final out = <({double from, double to})>[];
  for (final p in loop) {
    if (p.place != place) continue;
    if (out.isNotEmpty && p.d - out.last.to < 3) {
      out.last = (from: out.last.from, to: p.d);
    } else {
      out.add((from: p.d, to: p.d));
    }
  }
  return out;
}

/// The loop's middle, a point every 4 m, to find the nearest bit of it to anywhere (further than nearLoop reaches).
final List<RoadPoint> _coarse = [for (var i = 0; i < loop.length; i += 2) loop[i]];

({double off, ScenicPlace place, double d}) nearest(double x, double z) {
  var best = _coarse.first;
  var bestSq = double.infinity;
  for (final p in _coarse) {
    final sq = (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z);
    if (sq < bestSq) {
      bestSq = sq;
      best = p;
    }
  }
  return (off: math.sqrt(bestSq), place: best.place, d: best.d);
}

/// The loop and the street between its ends, as one closed outline.
final List<XZ> _ring = [for (final p in loop) (x: p.x, z: p.z), (x: 0.0, z: streetZ)];

bool insideLoop(double x, double z) {
  var inside = false;
  for (var i = 0, j = _ring.length - 1; i < _ring.length; j = i++) {
    final a = _ring[i], b = _ring[j];
    if ((a.z > z) != (b.z > z) && x < ((b.x - a.x) * (z - a.z)) / (b.z - a.z) + a.x) inside = !inside;
  }
  return inside;
}

/// Distance from (x, z) to a line through [pts].
double distToLine(List<XZ> pts, double x, double z) {
  var best = double.infinity;
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final ex = b.x - a.x, ez = b.z - a.z;
    var len2 = ex * ex + ez * ez;
    if (len2 == 0) len2 = 1;
    final k = (((x - a.x) * ex + (z - a.z) * ez) / len2).clamp(0.0, 1.0);
    final dx = x - a.x - ex * k, dz = z - a.z - ez * k;
    best = math.min(best, math.sqrt(dx * dx + dz * dz));
  }
  return best;
}

bool inBox(FieldBox b, double x, double z, [double pad = 0]) =>
    x > b.minX - pad && x < b.maxX + pad && z > b.minZ - pad && z < b.maxZ + pad;

// ---- The kit -------------------------------------------------------------------------------------

/// The stretches things are built along, each merged a square of the map at a time (see scenic.dart).
enum Stretch { road, farm, forest, mountains, beach, meadow, coast }

/// Something drawn only when it's near enough to see through the haze (see Scenic.cull): its
/// footprint, and how high it stands over the street (the taller, the further off it shows).
class Seen {
  const Seen(this.minX, this.maxX, this.minZ, this.maxZ, [this.above = 10]);
  Seen.around(double x, double z, double r, [double above = 10]) : this(x - r, x + r, z - r, z + r, above);
  final double minX, maxX, minZ, maxZ, above;
}

/// Something added as it is (not merged): a strip of road, a field, the water, the tunnel.
class Loose {
  Loose(this.data, this.coat, {this.seen, this.at, this.shadow = false});
  final MeshData data;
  final Coat coat;

  /// Only drawn near enough to see; null, always.
  Seen? seen;

  /// Where it's put (none: where its vertices say).
  final vm.Matrix4? at;
  final bool shadow;
}

/// Text on a sign, which is never merged: [fit] meters wide at most, or [scale] times its own size.
class SignText {
  SignText(
    this.text,
    this.opts, {
    required this.x,
    required this.y,
    required this.z,
    this.rotY = 0,
    this.scale = 1,
    this.fit,
  });
  final String text;
  final TextOpts opts;
  final double x, y, z, rotY, scale;
  final double? fit;
}

/// What each part of the loop builds into (makeKit in the TS).
class ScenicKit {
  ScenicKit();

  /// What's added as it is: the road, the fields, the water, the tunnel.
  final List<Loose> root = [];

  /// The text on the signs.
  final List<SignText> labels = [];

  /// The one random sequence the whole loop is laid out from. Each part takes its numbers in turn, so
  /// the parts are built in the same order every time, or every tree would move.
  final double Function() rand = mulberry32(20260929);

  /// What's built along each stretch, before it's sorted into squares of the map and merged.
  final Map<Stretch, List<Clump>> parts = {for (final s in Stretch.values) s: []};

  /// Landmarks that show over the haze from further off than the rest: the silo, the windmill, the lighthouse.
  final List<Clump> silo = [], mill = [], light = [];

  /// What's built along stretch [s].
  List<Clump> of(Stretch s) => parts[s]!;

  final List<Collider> colliders = [];

  /// Soft halos round the bulbs at night (they go into NightParts.halos).
  final List<Halo> halos = [];

  /// A one-piece clump at (x, y, z) in stretch [s] (a mesh added to parts[s]).
  void put(
    Stretch s,
    MeshData data,
    Coat coat, {
    double x = 0,
    double y = 0,
    double z = 0,
    vm.Quaternion? rot,
    bool shadow = true,
  }) => putIn(parts[s]!, data, coat, x: x, y: y, z: z, rot: rot, shadow: shadow);

  /// Something round and [h] tall at (x, z) that you can't walk through: a trunk, a hay bale.
  void trunk(double x, double z, double r, double h) =>
      colliders.add(Collider(minX: x - r, maxX: x + r, minZ: z - r, maxZ: z + r, bottom: G, top: G + h));

  /// Where trees shouldn't go: taken by something else, or the road.
  final List<({double x, double z, double r})> taken = [];

  void take(double x, double z, double r) => taken.add((x: x, z: z, r: r));

  /// Whether nothing's taken within [r] of (x, z).
  bool free(double x, double z, double r) {
    for (final t in taken) {
      final dx = t.x - x, dz = t.z - z;
      final reach = t.r + r;
      if (dx * dx + dz * dz <= reach * reach) return false;
    }
    return true;
  }
}

/// A one-piece clump at (x, y, z), into [into] (a mesh added to a group).
void putIn(
  List<Clump> into,
  MeshData data,
  Coat coat, {
  double x = 0,
  double y = 0,
  double z = 0,
  vm.Quaternion? rot,
  bool shadow = true,
}) {
  final c = Clump(x: x, y: y, z: z);
  if (rot != null) c.rotation = rot;
  c.add(data, coat, shadow: shadow);
  into.add(c);
}
