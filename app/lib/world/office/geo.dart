// Geometry and transform helpers for the office: three.js's primitives in its own orientation
// (planes, circles, rings and tori in XY facing +z; cones apex up), and ExtrudeGeometry of Shapes
// with holes, triangulated by ear clipping. Primitives are cached by their parameters, since the
// office builds hundreds of the same box.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../toon.dart';

final Map<String, Geometry> _cache = {};

Geometry _cached(String key, Geometry Function() make) => _cache[key] ??= make();

/// A w x h x d box, centred (three's BoxGeometry).
Geometry box(double w, double h, double d) => _cached('box $w $h $d', () => CuboidGeometry(vm.Vector3(w, h, d)));

/// three's CylinderGeometry(radiusTop, radiusBottom, height, radialSegments, 1, openEnded).
Geometry cyl(double rt, double rb, double h, [int seg = 8, bool open = false]) => _cached(
  'cyl $rt $rb $h $seg $open',
  () => CylinderGeometry(topRadius: rt, bottomRadius: rb, height: h, radialSegments: seg, topCap: !open, bottomCap: !open),
);

/// three's ConeGeometry(radius, height, radialSegments, 1, openEnded): apex up.
Geometry cone(double r, double h, [int seg = 8, bool open = false]) => _cached(
  'cone $r $h $seg $open',
  () => CylinderGeometry(topRadius: 0, bottomRadius: r, height: h, radialSegments: seg, bottomCap: !open),
);

/// three's SphereGeometry(radius, widthSegments, heightSegments).
Geometry sphere(double r, [int w = 12, int h = 10]) =>
    _cached('sphere $r $w $h', () => SphereGeometry(radius: r, segments: w, rings: h));

/// A geometry moved by [m] (three's geometry.rotateX / translate…).
Geometry transformed(Geometry g, vm.Matrix4 m) => MeshGeometry.fromMeshData(g.extractMeshData().transformed(m));

vm.Matrix4 rotX(double a) => vm.Matrix4.rotationX(a);
vm.Matrix4 rotZ(double a) => vm.Matrix4.rotationZ(a);

/// three's Euler (XYZ order) as a quaternion: `rotation.set(x, y, z)`.
vm.Quaternion euler(double x, [double y = 0, double z = 0]) =>
    vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), x) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), y) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), z);

vm.Quaternion yaw(double a) => vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), a);

/// The turn that points an object's +z along [dir] (three's Object3D.lookAt, for non-cameras).
vm.Quaternion lookAlong(vm.Vector3 dir) {
  final h = math.sqrt(dir.x * dir.x + dir.z * dir.z);
  return yaw(math.atan2(dir.x, dir.z)) * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -math.atan2(dir.y, h));
}

/// A node, placed and turned.
Node place(Node n, {double x = 0, double y = 0, double z = 0, vm.Quaternion? rot, double? scale, vm.Vector3? scale3}) {
  n.position = vm.Vector3(x, y, z);
  if (rot != null) n.rotation = rot;
  if (scale3 != null) {
    n.scale = scale3;
  } else if (scale != null) {
    n.scale = vm.Vector3.all(scale);
  }
  return n;
}

/// An empty node, like THREE.Group.
Node group([String name = '']) => Node(name: name);

/// Sets a toon material's glow to [color] at [intensity] (three's emissive x emissiveIntensity, in linear light).
void setEmissive(Material m, Color color, double intensity) {
  if (m is! PreprocessedMaterial) return;
  final l = linear(color);
  m.parameters.setVec4('emissive', vm.Vector4(l.x * intensity, l.y * intensity, l.z * intensity, 1));
}

/// Gives a toon material a texture (its base_color_texture), sampled the texture's own way.
void setToonTexture(Material m, Texture2D t) {
  if (m is! PreprocessedMaterial) return;
  m.parameters.setTexture('base_color_texture', t.gpuTexture, sampler: t.sampledSampler);
}

/// '#rrggbb' as a colour whose 8-bit channels hold linear light. The toon shader samples its
/// texture as-is (no sRGB decode), so canvases painted for it use these.
Color linColor(String h) {
  final l = linear(hex(h));
  return Color.from(alpha: 1, red: l.x, green: l.y, blue: l.z);
}

// ---------------------------------------------------------------------------------------------
// Flat things in three's orientation.

Float32List _f32(List<double> v) => Float32List.fromList(v);

/// A quad: corner [c] (its middle), half-extents along [r] (right) and [u] (up); faces r x u.
void _quad(List<double> p, List<double> uv, vm.Vector3 c, vm.Vector3 r, vm.Vector3 u, double su, double sv) {
  final bl = c - r - u, br = c + r - u, tr = c + r + u, tl = c - r + u;
  for (final v in [bl, br, tr, bl, tr, tl]) {
    p.addAll([v.x, v.y, v.z]);
  }
  uv.addAll([0, sv, su, sv, su, 0, 0, sv, su, 0, 0, 0]);
}

Geometry _flat(List<double> p, List<double> uv) =>
    MeshGeometry.fromMeshData(MeshData.build(positions: _f32(p), texCoords: _f32(uv)));

/// three's PlaneGeometry: w x h in XY, facing +z. With [both], it has a back face too (for
/// see-through glass, which the engine always culls on the back).
Geometry planeXY(double w, double h, {bool both = false}) => _cached('plane $w $h $both', () {
  final p = <double>[], uv = <double>[];
  _quad(p, uv, vm.Vector3.zero(), vm.Vector3(w / 2, 0, 0), vm.Vector3(0, h / 2, 0), 1, 1);
  if (both) _quad(p, uv, vm.Vector3.zero(), vm.Vector3(-w / 2, 0, 0), vm.Vector3(0, h / 2, 0), 1, 1);
  return _flat(p, uv);
});

/// A w x d plane lying flat, facing up, its UVs repeating [su] x [sv] times (a floor's planks).
Geometry groundPlane(double w, double d, [double su = 1, double sv = 1]) {
  final p = <double>[], uv = <double>[];
  _quad(p, uv, vm.Vector3.zero(), vm.Vector3(w / 2, 0, 0), vm.Vector3(0, 0, -d / 2), su, sv);
  return _flat(p, uv);
}

/// A plane with UVs of its own (the rain on a window, whose drops keep one size).
Geometry planeXYuv(double w, double h, double u0, double v0, double u1, double v1) {
  final x = w / 2, y = h / 2;
  return MeshGeometry.fromMeshData(
    MeshData.build(
      positions: _f32([-x, -y, 0, x, -y, 0, x, y, 0, -x, y, 0]),
      texCoords: _f32([u0, v1, u1, v1, u1, v0, u0, v0]),
      indices: [0, 1, 2, 0, 2, 3],
    ),
  );
}

/// three's CircleGeometry: a disc in XY facing +z.
Geometry circleXY(double r, [int seg = 16, bool both = false]) => ringXY(0, r, seg, both);

/// three's RingGeometry: an annulus in XY facing +z.
Geometry ringXY(double inner, double outer, [int seg = 32, bool both = false]) => _cached('ring $inner $outer $seg $both', () {
  final p = <double>[];
  for (var i = 0; i < seg; i++) {
    final a0 = i / seg * math.pi * 2, a1 = (i + 1) / seg * math.pi * 2;
    final c0 = math.cos(a0), s0 = math.sin(a0), c1 = math.cos(a1), s1 = math.sin(a1);
    void tri(List<double> t) {
      p.addAll(t);
      if (both) p.addAll([t[0], t[1], t[2], t[6], t[7], t[8], t[3], t[4], t[5]]);
    }

    tri([outer * c0, outer * s0, 0, outer * c1, outer * s1, 0, inner * c1, inner * s1, 0]);
    if (inner > 0) tri([outer * c0, outer * s0, 0, inner * c1, inner * s1, 0, inner * c0, inner * s0, 0]);
  }
  return MeshGeometry.fromMeshData(MeshData.build(positions: _f32(p)));
});

/// three's TorusGeometry(radius, tube, radialSegments, tubularSegments, arc): a ring in XY, the
/// arc running counter-clockwise from +x.
Geometry torusXY(double radius, double tube, [int radial = 8, int tubular = 24, double arc = math.pi * 2]) =>
    _cached('torus $radius $tube $radial $tubular $arc', () {
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
      return MeshGeometry.fromMeshData(MeshData.build(positions: _f32(pos), normals: _f32(nor), indices: idx));
    });

/// A tube of [radius] through [points] (three's TubeGeometry along a curve).
Geometry tubeThrough(List<vm.Vector3> points, double radius, [int radial = 4]) =>
    TubeGeometry(PolylinePath(points), radius: radius, radialSegments: radial, stations: points.length, caps: false);

/// A box whose six faces (+x, -x, +y, -y, +z, -z, as three orders them) each take their own
/// material (null leaves that face out), with UVs repeating [repeatV] times down the sides (a
/// building's floors of windows).
Node boxFaces(double w, double h, double d, List<Material?> mats, {double repeatV = 1}) {
  final hx = w / 2, hy = h / 2, hz = d / 2;
  final faces = <(vm.Vector3, vm.Vector3, vm.Vector3)>[
    (vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, -hz), vm.Vector3(0, hy, 0)),
    (vm.Vector3(-hx, 0, 0), vm.Vector3(0, 0, hz), vm.Vector3(0, hy, 0)),
    (vm.Vector3(0, hy, 0), vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, -hz)),
    (vm.Vector3(0, -hy, 0), vm.Vector3(hx, 0, 0), vm.Vector3(0, 0, hz)),
    (vm.Vector3(0, 0, hz), vm.Vector3(hx, 0, 0), vm.Vector3(0, hy, 0)),
    (vm.Vector3(0, 0, -hz), vm.Vector3(-hx, 0, 0), vm.Vector3(0, hy, 0)),
  ];
  final byMat = <Material, (List<double>, List<double>)>{};
  for (var i = 0; i < 6; i++) {
    final mat = mats[i];
    if (mat == null) continue;
    final (c, r, u) = faces[i];
    final (p, uv) = byMat[mat] ??= (<double>[], <double>[]);
    _quad(p, uv, c, r, u, 1, i == 2 || i == 3 ? 1 : repeatV);
  }
  return Node(
    mesh: Mesh.primitives(primitives: [for (final e in byMat.entries) MeshPrimitive(_flat(e.value.$1, e.value.$2), e.key)]),
  );
}

// ---------------------------------------------------------------------------------------------
// Shapes and extrusion (three's Shape / Path / ExtrudeGeometry).

/// A closed outline in XY, with holes: moveTo, lineTo, arcs and quadratic curves like three's.
class Shape2 {
  Shape2([this.curveSegments = 12]);

  /// How finely curves are cut (three's curveSegments; arcs get twice as many).
  int curveSegments;
  final List<vm.Vector2> points = [];
  final List<List<vm.Vector2>> holes = [];

  vm.Vector2 get _last => points.isEmpty ? vm.Vector2.zero() : points.last;

  void moveTo(double x, double y) => points.add(vm.Vector2(x, y));

  void lineTo(double x, double y) => points.add(vm.Vector2(x, y));

  void quadraticCurveTo(double cx, double cy, double x, double y) {
    final p0 = _last;
    for (var i = 1; i <= curveSegments; i++) {
      final t = i / curveSegments;
      final k = 1 - t;
      points.add(vm.Vector2(k * k * p0.x + 2 * k * t * cx + t * t * x, k * k * p0.y + 2 * k * t * cy + t * t * y));
    }
  }

  void absarc(double x, double y, double r, double a0, double a1, bool clockwise) =>
      points.addAll(arcPoints(x, y, r, a0, a1, clockwise, curveSegments * 2));

  /// A round hole (three's Path.absarc, pushed onto shape.holes).
  void addHoleArc(double x, double y, double r, double a0, double a1, bool clockwise) =>
      holes.add(arcPoints(x, y, r, a0, a1, clockwise, curveSegments * 2));

  void closePath() {}
}

/// Points along three's EllipseCurve (a circular one), start to end inclusive.
List<vm.Vector2> arcPoints(double x, double y, double r, double a0, double a1, bool clockwise, int n) {
  const twoPi = math.pi * 2;
  var delta = a1 - a0;
  final same = delta.abs() < 1e-12;
  while (delta < 0) {
    delta += twoPi;
  }
  while (delta > twoPi) {
    delta -= twoPi;
  }
  if (delta < 1e-12) delta = same ? 0 : twoPi;
  if (clockwise && !same) delta = delta == twoPi ? -twoPi : delta - twoPi;
  return [
    for (var i = 0; i <= n; i++) vm.Vector2(x + r * math.cos(a0 + i / n * delta), y + r * math.sin(a0 + i / n * delta)),
  ];
}

List<vm.Vector2> _clean(List<vm.Vector2> pts) {
  final out = <vm.Vector2>[];
  for (final p in pts) {
    if (out.isEmpty || (out.last - p).length2 > 1e-12) out.add(p);
  }
  while (out.length > 1 && (out.first - out.last).length2 < 1e-12) {
    out.removeLast();
  }
  return out;
}

double _area(List<vm.Vector2> pts) {
  var a = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i], q = pts[(i + 1) % pts.length];
    a += p.x * q.y - q.x * p.y;
  }
  return a / 2;
}

/// Pushes each point of a closed outline out by [d] along its corner's mitre (the solid's side
/// grows when the outline runs counter-clockwise).
List<vm.Vector2> _offset(List<vm.Vector2> pts, double d) {
  final n = pts.length;
  return [
    for (var i = 0; i < n; i++)
      () {
        final p = pts[(i - 1 + n) % n], c = pts[i], q = pts[(i + 1) % n];
        final e1 = (c - p)..normalize(), e2 = (q - c)..normalize();
        final n1 = vm.Vector2(e1.y, -e1.x), n2 = vm.Vector2(e2.y, -e2.x);
        final k = 1 + n1.dot(n2);
        if (k < 1e-3) return c + n1 * d;
        return c + (n1 + n2) * (d / k);
      }(),
  ];
}

/// three's ExtrudeGeometry(shape, {depth, bevel…}): the shape in XY, pushed out along +z from 0 to
/// [depth]. A bevel is a single chamfer [bevel] wide, reaching out past both ends like three's.
Geometry extrudeShape(Shape2 shape, double depth, {double bevel = 0}) {
  var outer = _clean(shape.points);
  if (_area(outer) < 0) outer = outer.reversed.toList();
  final holes = [
    for (final h in shape.holes)
      () {
        final c = _clean(h);
        return _area(c) > 0 ? c.reversed.toList() : c;
      }(),
  ];
  final tris = triangulate(outer, holes);
  final all = [...outer, for (final h in holes) ...h];
  final p = <double>[];
  void v(vm.Vector2 a, double z) => p.addAll([a.x, a.y, z]);
  final z0 = -bevel, z1 = depth + bevel;
  for (var i = 0; i < tris.length; i += 3) {
    final a = all[tris[i]], b = all[tris[i + 1]], c = all[tris[i + 2]];
    // Front cap faces +z; the back one, reversed, faces -z.
    v(a, z1);
    v(b, z1);
    v(c, z1);
    v(a, z0);
    v(c, z0);
    v(b, z0);
  }
  void side(List<vm.Vector2> ra, double za, List<vm.Vector2> rb, double zb) {
    for (var i = 0; i < ra.length; i++) {
      final j = (i + 1) % ra.length;
      v(ra[i], za);
      v(ra[j], za);
      v(rb[j], zb);
      v(ra[i], za);
      v(rb[j], zb);
      v(rb[i], zb);
    }
  }

  for (final contour in [outer, ...holes]) {
    if (bevel > 0) {
      final wide = _offset(contour, bevel);
      side(contour, z0, wide, 0);
      side(wide, 0, wide, depth);
      side(wide, depth, contour, z1);
    } else {
      side(contour, 0, contour, depth);
    }
  }
  return MeshGeometry.fromMeshData(MeshData.build(positions: _f32(p)));
}

double _cross(vm.Vector2 o, vm.Vector2 a, vm.Vector2 b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

bool _segmentsCross(vm.Vector2 a, vm.Vector2 b, vm.Vector2 c, vm.Vector2 d) {
  final d1 = _cross(a, b, c), d2 = _cross(a, b, d), d3 = _cross(c, d, a), d4 = _cross(c, d, b);
  return ((d1 > 1e-12 && d2 < -1e-12) || (d1 < -1e-12 && d2 > 1e-12)) &&
      ((d3 > 1e-12 && d4 < -1e-12) || (d3 < -1e-12 && d4 > 1e-12));
}

/// Triangulates a simple polygon ([outer] counter-clockwise) with [holes] (clockwise) by ear
/// clipping, after bridging each hole into the outline. Returns indices into outer ++ holes.
List<int> triangulate(List<vm.Vector2> outer, List<List<vm.Vector2>> holes) {
  final all = [...outer, for (final h in holes) ...h];
  var poly = [for (var i = 0; i < outer.length; i++) i];
  var start = outer.length;
  final holeIdx = <List<int>>[];
  for (final h in holes) {
    holeIdx.add([for (var i = 0; i < h.length; i++) start + i]);
    start += h.length;
  }
  // Rightmost holes first, each bridged to the nearest outline vertex it can see.
  holeIdx.sort((a, b) => a.map((i) => all[i].x).reduce(math.max).compareTo(b.map((i) => all[i].x).reduce(math.max)) * -1);
  for (var hi = 0; hi < holeIdx.length; hi++) {
    final hole = holeIdx[hi];
    var m = 0;
    for (var i = 1; i < hole.length; i++) {
      if (all[hole[i]].x > all[hole[m]].x) m = i;
    }
    final mp = all[hole[m]];
    bool visible(int pi) {
      final pp = all[pi];
      final edges = <(vm.Vector2, vm.Vector2)>[
        for (var i = 0; i < poly.length; i++) (all[poly[i]], all[poly[(i + 1) % poly.length]]),
        for (final other in holeIdx.skip(hi))
          for (var i = 0; i < other.length; i++) (all[other[i]], all[other[(i + 1) % other.length]]),
      ];
      for (final (a, b) in edges) {
        if (_segmentsCross(mp, pp, a, b)) return false;
      }
      return true;
    }

    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i < poly.length; i++) {
      final d = (all[poly[i]] - mp).length2 + (all[poly[i]].x < mp.x ? 1e6 : 0);
      if (d < bestD && visible(poly[i])) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) best = 0;
    poly = [
      ...poly.sublist(0, best + 1),
      for (var k = 0; k <= hole.length; k++) hole[(m + k) % hole.length],
      poly[best],
      ...poly.sublist(best + 1),
    ];
  }
  // Ear clipping.
  final out = <int>[];
  final ring = [...poly];
  var guard = 0;
  while (ring.length > 3 && guard++ < 100000) {
    var clipped = false;
    for (var i = 0; i < ring.length; i++) {
      final ia = ring[(i - 1 + ring.length) % ring.length], ib = ring[i], ic = ring[(i + 1) % ring.length];
      final a = all[ia], b = all[ib], c = all[ic];
      final cr = _cross(a, b, c);
      if (cr <= 1e-12) continue;
      var ear = true;
      for (final j in ring) {
        final q = all[j];
        if ((q - a).length2 < 1e-12 || (q - b).length2 < 1e-12 || (q - c).length2 < 1e-12) continue;
        if (_cross(a, b, q) >= -1e-12 && _cross(b, c, q) >= -1e-12 && _cross(c, a, q) >= -1e-12) {
          ear = false;
          break;
        }
      }
      if (!ear) continue;
      out.addAll([ia, ib, ic]);
      ring.removeAt(i);
      clipped = true;
      break;
    }
    if (!clipped) {
      // Degenerate leftovers (collinear runs): drop a flat vertex and carry on.
      var dropped = false;
      for (var i = 0; i < ring.length; i++) {
        final a = all[ring[(i - 1 + ring.length) % ring.length]], b = all[ring[i]], c = all[ring[(i + 1) % ring.length]];
        if (_cross(a, b, c).abs() <= 1e-12) {
          ring.removeAt(i);
          dropped = true;
          break;
        }
      }
      if (!dropped) break;
    }
  }
  if (ring.length == 3 && _cross(all[ring[0]], all[ring[1]], all[ring[2]]) > 0) out.addAll(ring);
  return out;
}
