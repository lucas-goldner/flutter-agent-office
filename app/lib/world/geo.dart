// three.js's primitives, built the way three builds them, so ports of the old models keep their
// shapes, orientations and faceting: partial spheres (hair caps), torus arcs (a smile, a headset
// band) and geometry.rotateX() baked in, none of which flutter_scene's own primitives do.
//
// Orientation matches three: a torus lies in XY, a cylinder/capsule/cone runs along Y (a cone's
// apex up), a sphere's phi runs round Y from -x (see [sphere]).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Positions, normals and triangles on their way to a [Geometry]. Triangles are wound so they face
/// the way their vertex normals point (counter-clockwise from outside), whatever order the
/// generator listed them in.
class GeoData {
  final List<double> p = [];
  final List<double> n = [];
  final List<int> idx = [];

  int get count => p.length ~/ 3;

  int vertex(double x, double y, double z, double nx, double ny, double nz) {
    p.addAll([x, y, z]);
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l > 0) {
      n.addAll([nx / l, ny / l, nz / l]);
    } else {
      n.addAll([0, 1, 0]);
    }
    return count - 1;
  }

  void tri(int a, int b, int c) {
    double px(int i, int k) => p[i * 3 + k];
    final ux = px(b, 0) - px(a, 0), uy = px(b, 1) - px(a, 1), uz = px(b, 2) - px(a, 2);
    final vx = px(c, 0) - px(a, 0), vy = px(c, 1) - px(a, 1), vz = px(c, 2) - px(a, 2);
    final cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
    if (cx * cx + cy * cy + cz * cz < 1e-18) return; // a sliver at a pole
    var dot = 0.0;
    for (final i in [a, b, c]) {
      dot += cx * n[i * 3] + cy * n[i * 3 + 1] + cz * n[i * 3 + 2];
    }
    if (dot >= 0) {
      idx.addAll([a, b, c]);
    } else {
      idx.addAll([a, c, b]);
    }
  }

  /// Bakes a transform in, like three's geometry.rotateX() / translate().
  GeoData transform(vm.Matrix4 m) {
    final nm = vm.Matrix3.zero()..copyNormalMatrix(m);
    for (var i = 0; i < count; i++) {
      final v = m.transform3(vm.Vector3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]));
      final nn = nm.transformed(vm.Vector3(n[i * 3], n[i * 3 + 1], n[i * 3 + 2]))..normalize();
      p.setRange(i * 3, i * 3 + 3, [v.x, v.y, v.z]);
      n.setRange(i * 3, i * 3 + 3, [nn.x, nn.y, nn.z]);
    }
    return this;
  }

  GeoData rotateX(double a) => transform(vm.Matrix4.rotationX(a));

  Geometry build() => MeshGeometry.fromMeshData(
    MeshData.build(positions: Float32List.fromList(p), normals: Float32List.fromList(n), indices: idx),
  );
}

/// three's SphereGeometry(radius, widthSegments, heightSegments, phiStart, phiLength, thetaStart,
/// thetaLength): x = -r cos(phi) sin(theta), y = r cos(theta), z = r sin(phi) sin(theta).
GeoData sphereData(
  double radius, [
  int widthSegments = 32,
  int heightSegments = 16,
  double phiStart = 0,
  double phiLength = math.pi * 2,
  double thetaStart = 0,
  double thetaLength = math.pi,
]) {
  final g = GeoData();
  final grid = <List<int>>[];
  for (var iy = 0; iy <= heightSegments; iy++) {
    final v = iy / heightSegments;
    final row = <int>[];
    for (var ix = 0; ix <= widthSegments; ix++) {
      final u = ix / widthSegments;
      final phi = phiStart + u * phiLength, theta = thetaStart + v * thetaLength;
      final x = -math.cos(phi) * math.sin(theta), y = math.cos(theta), z = math.sin(phi) * math.sin(theta);
      row.add(g.vertex(x * radius, y * radius, z * radius, x, y, z));
    }
    grid.add(row);
  }
  for (var iy = 0; iy < heightSegments; iy++) {
    for (var ix = 0; ix < widthSegments; ix++) {
      final a = grid[iy][ix + 1], b = grid[iy][ix], c = grid[iy + 1][ix], d = grid[iy + 1][ix + 1];
      g.tri(a, b, d);
      g.tri(b, c, d);
    }
  }
  return g;
}

Geometry sphere(
  double radius, [
  int widthSegments = 32,
  int heightSegments = 16,
  double phiStart = 0,
  double phiLength = math.pi * 2,
  double thetaStart = 0,
  double thetaLength = math.pi,
]) => sphereData(radius, widthSegments, heightSegments, phiStart, phiLength, thetaStart, thetaLength).build();

/// three's CylinderGeometry(radiusTop, radiusBottom, height, radialSegments), capped, along Y.
GeoData cylinderData(double radiusTop, double radiusBottom, double height, [int radialSegments = 32]) {
  final g = GeoData();
  final half = height / 2;
  final slope = (radiusBottom - radiusTop) / height;
  final rows = <List<int>>[];
  for (var y = 0; y <= 1; y++) {
    final r = y * (radiusBottom - radiusTop) + radiusTop;
    final row = <int>[];
    for (var x = 0; x <= radialSegments; x++) {
      final th = x / radialSegments * math.pi * 2;
      final s = math.sin(th), c = math.cos(th);
      row.add(g.vertex(r * s, -y * height + half, r * c, s, slope, c));
    }
    rows.add(row);
  }
  for (var x = 0; x < radialSegments; x++) {
    final a = rows[0][x], b = rows[1][x], c = rows[1][x + 1], d = rows[0][x + 1];
    g.tri(a, b, d);
    g.tri(b, c, d);
  }
  for (final (r, y, ny) in [(radiusTop, half, 1.0), (radiusBottom, -half, -1.0)]) {
    if (r <= 0) continue;
    final center = g.vertex(0, y, 0, 0, ny, 0);
    final ring = [
      for (var x = 0; x <= radialSegments; x++)
        g.vertex(r * math.sin(x / radialSegments * math.pi * 2), y, r * math.cos(x / radialSegments * math.pi * 2), 0, ny, 0),
    ];
    for (var x = 0; x < radialSegments; x++) {
      g.tri(center, ring[x], ring[x + 1]);
    }
  }
  return g;
}

Geometry cylinder(double radiusTop, double radiusBottom, double height, [int radialSegments = 32]) =>
    cylinderData(radiusTop, radiusBottom, height, radialSegments).build();

/// three's ConeGeometry(radius, height, radialSegments): apex up.
GeoData coneData(double radius, double height, [int radialSegments = 32]) => cylinderData(0, radius, height, radialSegments);

Geometry cone(double radius, double height, [int radialSegments = 32]) => coneData(radius, height, radialSegments).build();

/// three's CapsuleGeometry(radius, length, capSegments, radialSegments): a [length] tall middle
/// between two hemispheres, along Y.
GeoData capsuleData(double radius, double length, [int capSegments = 4, int radialSegments = 8]) {
  final g = GeoData();
  // The profile, pole to pole: (distance from the axis, y, normal's radial and y parts).
  final prof = <(double, double, double, double)>[];
  for (var i = 0; i <= capSegments; i++) {
    final a = math.pi / 2 * i / capSegments;
    prof.add((radius * math.sin(a), length / 2 + radius * math.cos(a), math.sin(a), math.cos(a)));
  }
  for (var i = 0; i <= capSegments; i++) {
    final a = math.pi / 2 + math.pi / 2 * i / capSegments;
    prof.add((radius * math.sin(a), -length / 2 + radius * math.cos(a), math.sin(a), math.cos(a)));
  }
  final rows = <List<int>>[];
  for (final (r, y, nr, ny) in prof) {
    rows.add([
      for (var x = 0; x <= radialSegments; x++)
        g.vertex(
          r * math.sin(x / radialSegments * math.pi * 2),
          y,
          r * math.cos(x / radialSegments * math.pi * 2),
          nr * math.sin(x / radialSegments * math.pi * 2),
          ny,
          nr * math.cos(x / radialSegments * math.pi * 2),
        ),
    ]);
  }
  for (var i = 0; i < rows.length - 1; i++) {
    for (var x = 0; x < radialSegments; x++) {
      final a = rows[i][x], b = rows[i + 1][x], c = rows[i + 1][x + 1], d = rows[i][x + 1];
      g.tri(a, b, d);
      g.tri(b, c, d);
    }
  }
  return g;
}

Geometry capsule(double radius, double length, [int capSegments = 4, int radialSegments = 8]) =>
    capsuleData(radius, length, capSegments, radialSegments).build();

/// three's TorusGeometry(radius, tube, radialSegments, tubularSegments, arc): in the XY plane,
/// the arc running from +x counter-clockwise toward +y.
GeoData torusData(double radius, double tube, [int radialSegments = 12, int tubularSegments = 48, double arc = math.pi * 2]) {
  final g = GeoData();
  final grid = <List<int>>[];
  for (var j = 0; j <= radialSegments; j++) {
    final row = <int>[];
    for (var i = 0; i <= tubularSegments; i++) {
      final u = i / tubularSegments * arc;
      final v = j / radialSegments * math.pi * 2;
      final x = (radius + tube * math.cos(v)) * math.cos(u);
      final y = (radius + tube * math.cos(v)) * math.sin(u);
      final z = tube * math.sin(v);
      row.add(g.vertex(x, y, z, x - radius * math.cos(u), y - radius * math.sin(u), z));
    }
    grid.add(row);
  }
  for (var j = 1; j <= radialSegments; j++) {
    for (var i = 1; i <= tubularSegments; i++) {
      final a = grid[j][i - 1], b = grid[j - 1][i - 1], c = grid[j - 1][i], d = grid[j][i];
      g.tri(a, b, d);
      g.tri(b, c, d);
    }
  }
  return g;
}

Geometry torus(double radius, double tube, [int radialSegments = 12, int tubularSegments = 48, double arc = math.pi * 2]) =>
    torusData(radius, tube, radialSegments, tubularSegments, arc).build();

/// three's BoxGeometry(w, h, d).
Geometry box(double w, double h, double d) => CuboidGeometry(vm.Vector3(w, h, d));

/// three's `rotation.set(x, y, z)` (Euler order XYZ) as a quaternion.
vm.Quaternion euler(double x, double y, [double z = 0]) =>
    vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), x) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), y) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), z);

/// A node whose rotation is kept as three-style Euler angles, for joints the animation code turns
/// one axis at a time (`arm.rotation.x = ...` in the old client). Set [x]/[y]/[z], then [apply].
class Pivot {
  Pivot([Node? node]) : node = node ?? Node();

  final Node node;
  double x = 0, y = 0, z = 0;

  void apply() => node.rotation = euler(x, y, z);

  void add(Node child) => node.add(child);

  set position(vm.Vector3 p) => node.position = p;
}

/// [p] in [node]'s local space, carried into [space]'s local space (world space when [space] is
/// null). The office sits under a mirroring root (flutter_scene is left-handed), so "world"
/// positions the old client handed around (smoke puffs, a cigarette's tip) are given in the
/// space of the node the office is built in instead: pass that node, or the node's parent.
vm.Vector3 pointIn(Node? space, Node node, vm.Vector3 p) {
  final w = node.globalTransform.transform3(p.clone());
  if (space == null) return w;
  return vm.Matrix4.inverted(space.globalTransform).transform3(w);
}
