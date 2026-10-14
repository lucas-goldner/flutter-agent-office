// What's outside the station's windows: the stars and the Milky Way, the Sun, the Earth turning below,
// the Moon, a ringed giant and a red planet. It all rides along with your eye, so it looks as far off
// as it is however you walk about. A port of world/station/space.ts.
//
// The old client drew it first, behind everything, without touching the depth buffer, and lit its
// worlds with shaders of their own. Here it's drawn where it is, far enough off that nothing in the
// room is ever behind it (the sky at 200 m, the Earth's near side 62 m off), with unlit materials:
// the Sun's light on each world, its night side, the cities' lights and the glow of its air are worked
// out once a vertex (they don't change: the worlds ride along with you, and the Sun's fixed), and a
// world turns by sliding its picture round it. The Earth's clouds are painted onto its day side, so
// they turn with it rather than drifting over it.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../office/parts.dart' show canvasTexture;
import 'kit.dart' show seeded, unlitPicture;
import 'planets.dart';

/// Where something is in the sky: [az] degrees round from forward (north, -z) toward starboard (east,
/// +x), [el] degrees up.
vm.Vector3 skyward(double az, double el) {
  final a = az * math.pi / 180, e = el * math.pi / 180;
  return vm.Vector3(math.sin(a) * math.cos(e), math.sin(e), -math.cos(a) * math.cos(e));
}

/// The way to the Sun: high off the port bow, so the Earth off to starboard is in daylight but for its far edge.
final vm.Vector3 sunward = skyward(-62, 36);

/// The Earth: off the starboard bow and below, filling that side of the sky.
final vm.Vector3 _earthAt = skyward(56, -27);
const double _earthFar = 160, _earthRadius = 98;

/// How far off the planets are, and the sky behind them all (beyond the Earth's limb, 126 m off).
const double _far = 108;
const double _sky = 200;

double _smooth(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// A sphere of [r] at [at] (in the backdrop's space), tipped over by [tilt] about z, with three's
/// SphereGeometry's layout (its picture's top at the north pole), each vertex's colour from [color]
/// (handed the vertex's normal and where it is). [both]: wound both ways, for see-through layers,
/// whose back faces the engine always culls.
Geometry _globe(
  double r,
  vm.Vector3 at,
  double tilt,
  int ws,
  int hs,
  vm.Vector4 Function(vm.Vector3 n, vm.Vector3 p) color, {
  bool both = false,
}) {
  final rot = vm.Matrix3.rotationZ(tilt);
  final p = <double>[], n = <double>[], uv = <double>[], c = <double>[];
  final idx = <int>[];
  for (var iy = 0; iy <= hs; iy++) {
    final v = iy / hs;
    for (var ix = 0; ix <= ws; ix++) {
      final u = ix / ws;
      final phi = u * math.pi * 2, theta = v * math.pi;
      final nn = rot.transformed(
        vm.Vector3(-math.cos(phi) * math.sin(theta), math.cos(theta), math.sin(phi) * math.sin(theta)),
      );
      final pos = at + nn * r;
      p.addAll([pos.x, pos.y, pos.z]);
      n.addAll([nn.x, nn.y, nn.z]);
      // The engine's v runs down the picture: 0 at the north pole.
      uv.addAll([u, v]);
      final col = color(nn, pos);
      c.addAll([col.x, col.y, col.z, col.w]);
    }
  }
  for (var iy = 0; iy < hs; iy++) {
    for (var ix = 0; ix < ws; ix++) {
      final a = iy * (ws + 1) + ix + 1, b = iy * (ws + 1) + ix;
      final cc = (iy + 1) * (ws + 1) + ix, d = (iy + 1) * (ws + 1) + ix + 1;
      idx.addAll([a, b, d, b, cc, d]);
      if (both) idx.addAll([a, d, b, b, d, cc]);
    }
  }
  return MeshGeometry.fromMeshData(
    MeshData.build(
      positions: Float32List.fromList(p),
      normals: Float32List.fromList(n),
      texCoords: Float32List.fromList(uv),
      colors: Float32List.fromList(c),
      indices: idx,
    ),
  );
}

/// How the Sun lights a world's surface where its normal is [n] (PLANET_FRAG's day side): a cartoon's
/// two tones of daylight, a little earthshine on the night side, and its [air] glowing toward its edge
/// as seen from the middle of it all (where you are).
vm.Vector4 _sunlit(vm.Vector3 n, vm.Vector3 p, vm.Vector3? air) {
  final light = n.dot(sunward);
  final lit = _smooth(-0.1, 0.22, light);
  final tone = 0.62 + (1.0 - 0.62) * _smooth(0.32, 0.4, light);
  final k = lit * tone * 1.08 + 0.03 * (1 - lit);
  var out = vm.Vector3.all(k);
  if (air != null) {
    final view = -p.normalized();
    final rim = math.pow(1 - math.max(n.dot(view), 0.0), 2.6).toDouble();
    // The air's glow was added to the ground's colour; here it lifts what the ground's multiplied by.
    out += air * (rim * (0.12 + 0.95 * lit) * 2.2);
  }
  return vm.Vector4(out.x, out.y, out.z, 1);
}

vm.Vector3 _linear(int rgb) {
  double ch(int v) {
    final c = v / 255;
    return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  return vm.Vector3(ch((rgb >> 16) & 0xff), ch((rgb >> 8) & 0xff), ch(rgb & 0xff));
}

/// A flat square [size] across at [at], facing the middle of it all, wound both ways.
Geometry _facing(vm.Vector3 at, double size) {
  final dir = at.normalized();
  var u = vm.Vector3(-dir.z, 0, dir.x);
  if (u.length2 < 1e-9) u = vm.Vector3(1, 0, 0);
  u.normalize();
  final v = dir.cross(u)..normalize();
  final h = size / 2;
  final corners = [at - u * h - v * h, at + u * h - v * h, at + u * h + v * h, at - u * h + v * h];
  return MeshGeometry.fromMeshData(
    MeshData.build(
      positions: Float32List.fromList([
        for (final q in corners) ...[q.x, q.y, q.z],
      ]),
      texCoords: Float32List.fromList([0, 1, 1, 1, 1, 0, 0, 0]),
      indices: [0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2],
    ),
  );
}

/// The stars: a little diamond each, facing you, all in one mesh, each its own colour.
Geometry _stars() {
  final rand = seeded(3);
  final pos = <double>[], col = <double>[];
  const r = _sky * 0.95;
  // As big for how far off they are as the old client's.
  const grow = r / (120 * 0.95);
  for (var i = 0; i < 4200; i++) {
    final y = rand() * 2 - 1;
    final a = rand() * math.pi * 2;
    final rr = math.sqrt(1 - y * y);
    final at = vm.Vector3(math.cos(a) * rr, y, math.sin(a) * rr);
    // Across the line of sight, two ways.
    var u = vm.Vector3(-at.z, 0, at.x);
    if (u.length2 < 1e-12) u = vm.Vector3(1, 0, 0);
    u.normalize();
    final v = at.cross(u);
    // Most are faint and small; one in six is bright, and bigger.
    final bright = i % 6 == 0;
    final h = (bright ? 0.1 : 0.05) * (0.7 + rand() * 0.6) * grow;
    final corners = [
      for (final (du, dv) in [(h, 0.0), (0.0, h), (-h, 0.0), (0.0, -h)]) at * r + u * du + v * dv,
    ];
    for (final k in const [0, 1, 2, 0, 2, 3]) {
      pos.addAll([corners[k].x, corners[k].y, corners[k].z]);
    }
    // Most are white; a few are blue, and a few amber.
    final tint = rand();
    final b = bright ? 0.75 + rand() * 0.25 : 0.25 + rand() * 0.45;
    for (var k = 0; k < 6; k++) {
      col.addAll([
        b * (tint > 0.85 ? 0.75 : 1),
        b * (tint > 0.85 ? 0.85 : (tint < 0.12 ? 0.85 : 1)),
        b * (tint < 0.12 ? 0.6 : 1),
        1,
      ]);
    }
  }
  return MeshGeometry.fromMeshData(
    MeshData.build(positions: Float32List.fromList(pos), colors: Float32List.fromList(col)),
  );
}

/// A giant's rings: an annulus from [inner] to [outer] round [at], tipped by [tilt] (three's Euler,
/// XYZ), its picture running across the rings, wound both ways.
Geometry _rings(vm.Vector3 at, double inner, double outer, vm.Matrix3 tilt) {
  const seg = 96;
  final p = <double>[], uv = <double>[];
  void vert(double r, double a) {
    final q = at + tilt.transformed(vm.Vector3(r * math.cos(a), r * math.sin(a), 0));
    p.addAll([q.x, q.y, q.z]);
    uv.addAll([(r - inner) / (outer - inner), 0.5]);
  }

  for (var i = 0; i < seg; i++) {
    final a0 = i / seg * math.pi * 2, a1 = (i + 1) / seg * math.pi * 2;
    for (final (r0, b0, r1, b1, r2, b2) in [
      (inner, a0, outer, a0, outer, a1),
      (inner, a0, outer, a1, inner, a1),
      (inner, a0, outer, a1, outer, a0),
      (inner, a0, inner, a1, outer, a1),
    ]) {
      vert(r0, b0);
      vert(r1, b1);
      vert(r2, b2);
    }
  }
  return MeshGeometry.fromMeshData(
    MeshData.build(positions: Float32List.fromList(p), texCoords: Float32List.fromList(uv)),
  );
}

/// The glow of a world's air past its edge, seen from the middle of it all: an annulus round the
/// world's outline, on the plane its outline lies in, bright at the edge and gone by [shell] times its
/// radius, lit where the Sun's on it (AIR_FRAG).
Geometry _airGlow(vm.Vector3 at, double r, double shell, vm.Vector3 air) {
  final d = at.length;
  final dir = at / d;
  var u = vm.Vector3(-dir.z, 0, dir.x)..normalize();
  final v = dir.cross(u)..normalize();
  // Where the outline is: the circle the eye's sight lines graze the world along.
  final plane = (d * d - r * r) / d;
  final edge = r * math.sqrt(d * d - r * r) / d;
  final rs = r * shell;
  final outer = rs * math.sqrt(d * d - rs * rs) / (d * d - rs * rs) * plane;
  const seg = 128, steps = 8;
  final p = <double>[], c = <double>[];
  final idx = <int>[];
  final mid = at.normalized() * plane;
  for (var j = 0; j <= steps; j++) {
    // A little inside the outline, so no gap shows; the world in front of it hides that part.
    final k = j / steps;
    final radius = edge * 0.995 + (outer - edge * 0.995) * k;
    final f = math.pow(1 - k, 2.4).toDouble();
    for (var i = 0; i <= seg; i++) {
      final a = i / seg * math.pi * 2;
      final off = u * math.cos(a) + v * math.sin(a);
      final q = mid + off * radius;
      final lit = _smooth(-0.2, 0.3, off.dot(sunward));
      final alpha = (f * (0.1 + 0.9 * lit)).clamp(0.0, 1.0);
      p.addAll([q.x, q.y, q.z]);
      c.addAll([air.x, air.y, air.z, alpha]);
    }
  }
  for (var j = 0; j < steps; j++) {
    for (var i = 0; i < seg; i++) {
      final a = j * (seg + 1) + i, b = a + 1, cc = a + seg + 1, dd = cc + 1;
      idx.addAll([a, b, dd, a, dd, cc, a, dd, b, a, cc, dd]);
    }
  }
  return MeshGeometry.fromMeshData(
    MeshData.build(positions: Float32List.fromList(p), colors: Float32List.fromList(c), indices: idx),
  );
}

class Space {
  Space() {
    // The sky itself: the Milky Way painted on it, and the stars drawn over it one by one, so they stay sharp.
    final sky = unlitPicture(canvasTexture(2048, 1024, starfield(2048, 1024)))..doubleSided = true;
    _add(_globe(_sky, vm.Vector3.zero(), 0, 48, 32, (_, _) => vm.Vector4(1, 1, 1, 1)), sky);
    _add(_stars(), UnlitMaterial()..doubleSided = true);

    // The Sun: all glare.
    final sunAt = sunward * (_sky * 0.9);
    _add(
      _facing(sunAt, 74 * (_sky * 0.9) / (120 * 0.9)),
      unlitPicture(canvasTexture(512, 512, sunGlare(512)), blend: true),
    );

    // The Moon, over the bow; a red planet, small and far, off to starboard.
    _moon = _world(skyward(-14, 21) * _far, 4.2, 0.2, canvasTexture(512, 256, moonFace(512, 256)));
    _world(skyward(104, 24) * _far, 1.9, 0.4, canvasTexture(256, 128, redPlanet(256, 128)), air: 0xff9a7a);

    // A ringed giant off to port, its rings round it.
    final giantAt = skyward(-104, 13) * _far;
    _giant = _world(
      giantAt,
      7.4,
      0.38,
      canvasTexture(
        256,
        256,
        bands(256, 256, const ['#e6cf9c', '#d9b77a', '#f0e2bd', '#c79a5e', '#e9d7a8', '#b98a55'], 61),
      ),
      air: 0xffe6b0,
    );
    final ringTilt = vm.Matrix3.rotationX(math.pi / 2 - 0.42) * vm.Matrix3.rotationZ(0.38) as vm.Matrix3;
    final ringMat = unlitPicture(canvasTexture(256, 4, rings(256, 4)), blend: true);
    _add(_rings(giantAt, 9.4, 16.5, ringTilt), ringMat);

    // The Earth, its cities' lights on its night side, and the glow of its air round its edge.
    final at = _earthAt * _earthFar;
    const tilt = 0.41;
    _earth = _world(
      at,
      _earthRadius,
      tilt,
      earthClouds(512, 256).then((clouds) => canvasTexture(2048, 1024, earthWithClouds(2048, 1024, clouds))),
      air: 0x4d9dff,
      ws: 96,
      hs: 64,
    );
    _night = unlitPicture(canvasTexture(1024, 512, earthNight(1024, 512)), blend: true);
    _add(
      _globe(_earthRadius * 1.002, at, tilt, 96, 64, (n, _) {
        final dark = 1 - _smooth(-0.1, 0.22, n.dot(sunward));
        return vm.Vector4(1.7, 1.7, 1.7, dark);
      }, both: true),
      _night,
    );
    final airMat = UnlitMaterial()..alphaMode = AlphaMode.blend;
    _add(_airGlow(at, _earthRadius, 1.045, _linear(0x5fb0ff)), airMat);
  }

  final Node group = Node(name: 'space');
  late final UnlitMaterial _moon, _giant, _earth, _night;

  void _add(Geometry geo, Material mat) => group.add(Node(mesh: Mesh(geo, mat))..castsShadows = false);

  /// A world [r] across (half of it) at [at], tipped over by [tilt], with its picture and, if it has
  /// one, the glow of its [air] round its edge. Returns its material, to turn it by.
  UnlitMaterial _world(
    vm.Vector3 at,
    double r,
    double tilt,
    Future<Texture2D> picture, {
    int? air,
    int ws = 64,
    int hs = 40,
  }) {
    final mat = unlitPicture(picture)..doubleSided = true;
    final glow = air == null ? null : _linear(air);
    _add(_globe(r, at, tilt, ws, hs, (n, p) => _sunlit(n, p, glow)), mat);
    return mat;
  }

  /// Rides along with [eye], and turns the worlds.
  void update(double t, vm.Vector3 eye) {
    group.position = eye.clone();
    // The Earth turns under you (it's you going round it); the Moon and the giant, slowly.
    final earth = (t * 0.012 / (math.pi * 2)) % 1;
    _earth.baseColorTextureTransform.offset = vm.Vector2(-earth, 0);
    _night.baseColorTextureTransform.offset = vm.Vector2(-earth, 0);
    _moon.baseColorTextureTransform.offset = vm.Vector2(-(t * 0.004 / (math.pi * 2)) % 1, 0);
    _giant.baseColorTextureTransform.offset = vm.Vector2(-(t * 0.02 / (math.pi * 2)) % 1, 0);
  }
}
