// The tunnel through the spur (world/scenic/tunnel.ts): the rock round it, its lining and lamps, the
// road through it and an arch at each end.

import 'dart:math' as math;

import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../office/geo.dart' show Shape2, triangulate;
import '../text.dart' show TextOpts;
import 'kit.dart';
import 'road.dart';

double _area(List<vm.Vector2> pts) {
  var a = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i], q = pts[(i + 1) % pts.length];
    a += p.x * q.y - q.x * p.y;
  }
  return a / 2;
}

/// The spur, as three's ExtrudeGeometry(shape with a hole, {depth, steps}) would make it: its two ends
/// (the cliffs the tunnel's mouths are cut in) and its sides, which go along it in [steps].
({List<double> ends, List<double> sides}) _extrude(
  List<vm.Vector2> outer,
  List<vm.Vector2> hole,
  double depth,
  int steps,
) {
  if (_area(outer) < 0) outer = outer.reversed.toList();
  if (_area(hole) > 0) hole = hole.reversed.toList();
  final tris = triangulate(outer, [hole]);
  final all = [...outer, ...hole];
  final ends = <double>[], sides = <double>[];
  void v(List<double> into, vm.Vector2 a, double z) => into.addAll([a.x, a.y, z]);
  for (var i = 0; i < tris.length; i += 3) {
    final a = all[tris[i]], b = all[tris[i + 1]], c = all[tris[i + 2]];
    v(ends, a, depth);
    v(ends, b, depth);
    v(ends, c, depth);
    v(ends, a, 0);
    v(ends, c, 0);
    v(ends, b, 0);
  }
  for (final ring in [outer, hole]) {
    for (var s = 0; s < steps; s++) {
      final z0 = depth * s / steps, z1 = depth * (s + 1) / steps;
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i], b = ring[(i + 1) % ring.length];
        v(sides, a, z0);
        v(sides, b, z0);
        v(sides, b, z1);
        v(sides, a, z0);
        v(sides, b, z1);
        v(sides, a, z1);
      }
    }
  }
  return (ends: ends, sides: sides);
}

/// The tunnel: the spur over it, its lining and lamps, the road through it and an arch at each end.
void buildTunnel(ScenicKit kit, RoadInfo road) {
  const half = Tunnel.width / 2;
  const archR = half;
  const len = Tunnel.x0 - Tunnel.x1;
  // The spur's shape across the road (u is meters south of it), with the tunnel's arch through it.
  const profile = [
    (-Ridge.north, -0.6),
    (-Ridge.north, 0.0),
    (-24.0, 5.0),
    (-17.0, 11.0),
    (-10.0, 16.0),
    (-4.0, 19.0),
    (3.0, 23.0),
    (10.0, Ridge.height - 1),
    (17.0, Ridge.height),
    (24.0, 23.0),
    (31.0, 15.0),
    (36.0, 7.0),
    (Ridge.south, 0.0),
    (Ridge.south, -0.6),
  ];
  final outer = [for (final (u, y) in profile) vm.Vector2(u, y)];
  final hole = Shape2(14)
    ..moveTo(-half, -0.3)
    ..lineTo(half, -0.3)
    ..lineTo(half, Tunnel.wall)
    ..absarc(0, Tunnel.wall, archR, 0, math.pi, false);
  // (lineTo(-half, -0.3) closes it, back where it started.)
  // (The arc starts where the line up the hole's east side stops: that point's only wanted once.)
  final holePts = <vm.Vector2>[];
  for (final q in hole.points) {
    if (holePts.isEmpty || (holePts.last - q).length2 > 1e-10) holePts.add(q);
  }
  final spur = _extrude(outer, holePts, len, 12);
  // Across the road (u) is z, and along it is -x from the east end (three's rotateY(-π/2), then
  // moved to the east end). Humped up in the middle and down toward its ends, so the cliff each end
  // of the tunnel is cut in isn't the whole spur's height and width; lumpy along the top. None of it
  // round the arch, so the lining fits (and an end's corners only move up and down or across, so
  // each end stays flat).
  const top = Tunnel.wall + archR + 1;
  List<double> placed(List<double> p) {
    final out = List<double>.filled(p.length, 0);
    for (var i = 0; i < p.length; i += 3) {
      final u = p[i];
      var y = p[i + 1];
      final x = Tunnel.x0 - p[i + 2];
      var z = Tunnel.z + u;
      final k = math.pow(math.max(0.0, math.sin((math.pi * (Tunnel.x0 - x)) / len)), 0.6).toDouble();
      if (u.abs() > half + 1.5) z = Tunnel.z + u.sign * (half + 1.5 + (u.abs() - half - 1.5) * (0.45 + 0.55 * k));
      if (y > top) {
        y = top + (y - top) * (0.3 + 0.7 * k);
        y += (math.sin(x * 0.21 + u * 0.13) + math.sin(x * 0.07 - u * 0.31)) * 1.6 * k;
      }
      out[i] = x;
      out[i + 1] = G + y;
      out[i + 2] = z;
    }
    return out;
  }

  final tunnelBox = Seen(
    Tunnel.x1 - 20,
    Tunnel.x0 + 20,
    Tunnel.z - Ridge.north - 5,
    Tunnel.z + Ridge.south + 5,
    Ridge.height + 6,
  );
  // Its two ends are cliffs of rock, the tunnel's mouths in them; its sides and top are grass.
  kit.root
    ..add(Loose(faceted(placed(spur.ends)), const Coat.plain('#9a93a6'), seen: tunnelBox, shadow: true))
    ..add(Loose(faceted(placed(spur.sides)), const Coat.plain('#6f8f55'), seen: tunnelBox, shadow: true));

  // The walls and roof inside, a little in from the arch: dark rock, with a line of lamps along the top.
  const inset = 0.06;
  final arc = <(double, double)>[(-half + inset, -0.2)];
  for (var k = 0; k <= 16; k++) {
    final a = math.pi - (k / 16) * math.pi;
    arc.add((math.cos(a) * (archR - inset), Tunnel.wall + math.sin(a) * (archR - inset)));
  }
  arc.add((half - inset, -0.2));
  final pos = <double>[], col = <double>[];
  // Lit by its own lamps, not the sun: shaded by hand, walls lighter than the roof.
  final wall = vm.Vector3(0x5d / 255, 0x57 / 255, 0x66 / 255), roof = vm.Vector3(0x3b / 255, 0x36 / 255, 0x43 / 255);
  double lin(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  for (var k = 0; k < arc.length - 1; k++) {
    final (u0, y0) = arc[k];
    final (u1, y1) = arc[k + 1];
    final a = [Tunnel.x0, G + y0, Tunnel.z + u0];
    final b = [Tunnel.x0, G + y1, Tunnel.z + u1];
    final c = [Tunnel.x1, G + y1, Tunnel.z + u1];
    final d = [Tunnel.x1, G + y0, Tunnel.z + u0];
    final up = math.max(0.0, (y0 + y1) / 2 - Tunnel.wall) / archR;
    // three lerps its colours in linear light.
    final w = vm.Vector3(lin(wall.x), lin(wall.y), lin(wall.z));
    final r = vm.Vector3(lin(roof.x), lin(roof.y), lin(roof.z));
    final shade = w + (r - w) * math.min(1.0, up);
    // Seen from both sides (three's DoubleSide): each triangle both ways round.
    for (final t in [
      [a, b, c],
      [a, c, d],
      [a, c, b],
      [a, d, c],
    ]) {
      for (final p in t) {
        pos.addAll(p);
        col.addAll([shade.x, shade.y, shade.z, 1]);
      }
    }
  }
  kit.root.add(Loose(coloured(pos, col), Coat.lining, seen: tunnelBox));

  // The road through it, as dim as the walls whatever the sun's doing outside.
  Along end(double x) => Along(x, Tunnel.z, -1, 0, nearLoop(x, Tunnel.z)!.d);
  final through = [
    end(Tunnel.x0),
    for (final q in loop)
      if (q.x < Tunnel.x0 && q.x > Tunnel.x1 && (q.z - Tunnel.z).abs() < 1) alongOf(q),
    end(Tunnel.x1),
  ];
  kit.root
    ..add(
      Loose(
        strip(through, -loopHalf - 1.2, loopHalf + 1.2, G - 0.009, (_) => 0),
        const Coat.dim('#5e574c'),
        seen: tunnelBox,
      ),
    )
    ..add(
      Loose(
        strip(through, -loopHalf, loopHalf, G - 0.005, (i) => road.roadU(through[i].d)),
        const Coat.dim('#8d8d94', canvas: Painted.asphalt),
        seen: tunnelBox,
      ),
    );
  const lamp = Coat.bulb('#ffcf7a', 0.9);
  for (var x = Tunnel.x1 + 4; x < Tunnel.x0 - 2; x += 6) {
    for (final u in const [-2.2, 2.2]) {
      kit.put(
        Stretch.mountains,
        box(1.4, 0.12, 0.3),
        lamp,
        x: x,
        y: G + Tunnel.wall + archR - 0.9,
        z: Tunnel.z + u,
        shadow: false,
      );
    }
  }
  // A stone arch round each end, and the tunnel's name over it.
  const stone = Coat.plain('#cdc5b4');
  for (final (x, face) in const [(Tunnel.x0, math.pi / 2), (Tunnel.x1, -math.pi / 2)]) {
    final out = face.sign;
    kit.put(
      Stretch.mountains,
      torus(archR + 0.35, 0.45, 6, 16, math.pi),
      stone,
      x: x + out * 0.2,
      y: G + Tunnel.wall,
      z: Tunnel.z,
      rot: yawQ(math.pi / 2),
    );
    for (final u in const [-1, 1]) {
      kit.put(
        Stretch.mountains,
        box(0.9, Tunnel.wall, 0.9),
        stone,
        x: x + out * 0.2,
        y: G + Tunnel.wall / 2,
        z: Tunnel.z + u * (half + 0.35),
      );
    }
    kit.labels.add(
      SignText(
        '${ScenicPlace.tunnel.icon} ${ScenicPlace.tunnel.title.toUpperCase()}',
        const TextOpts(color: '#fefae0', bg: '#3d405b', size: 56, border: '#cdc5b4'),
        x: x + out * 0.35,
        y: G + Tunnel.wall + archR + 1.6,
        z: Tunnel.z,
        rotY: face,
        scale: 1.5,
      ),
    );
  }
  // Rock either side of the road in and out of it, north and south: nobody walks over the spur.
  kit.colliders
    ..add(
      Collider(
        minX: Tunnel.x1,
        maxX: Tunnel.x0,
        minZ: Tunnel.z - Ridge.north * 0.5,
        maxZ: Tunnel.z - half - 0.25,
        bottom: G - 1,
        top: G + 1000,
      ),
    )
    ..add(
      Collider(
        minX: Tunnel.x1,
        maxX: Tunnel.x0,
        minZ: Tunnel.z + half + 0.25,
        maxZ: Tunnel.z + Ridge.south * 0.5,
        bottom: G - 1,
        top: G + 1000,
      ),
    );
  kit.take((Tunnel.x0 + Tunnel.x1) / 2, Tunnel.z, 42);
}
