// The road round the scenic loop (world/scenic/road.ts): its asphalt and verges, the start line, the
// posts along it and the guardrail through the pass; and the signs to it and along it.

import 'dart:math' as math;

import 'package:office_shared/scenic.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../collider.dart';
import '../text.dart' show TextOpts;
import 'kit.dart';

/// What the rest of the loop takes from the road: where the creek crosses it, and how far along the
/// asphalt's picture each bit of it is.
class RoadInfo {
  RoadInfo(this.roadU, this.creekLine, this.bridge);

  /// How far along the asphalt's picture [d] meters round the loop is, so the dashes line up.
  final double Function(double d) roadU;

  /// The creek's line, and how far round the loop the bridge over it is.
  final List<XZ> creekLine;
  final double bridge;
}

/// The road round the loop: its asphalt and verges, the start line, the posts along it and the guardrail through the pass.
RoadInfo buildRoad(ScenicKit kit) {
  // The street's asphalt, lines and all, carried on round the loop; the dashes line up where they
  // meet. (The TS starts it a few meters back over the street's ends and draws it over the street's
  // with a polygon offset; here it starts right where the street's stops, so nothing overlaps.)
  final dashes = (loopLength / 8 + 0.5).round();
  double roadU(double d) => 0.5 + (d / loopLength) * (dashes - 0.5);
  final way = [for (final p in loop) alongOf(p)];
  kit.root.add(
    Loose(
      strip(way, -loopHalf, loopHalf, G - 0.008, (i) => roadU(way[i].d)),
      const Coat.flat('#ffffff', canvas: Painted.asphalt),
    ),
  );
  // The gravel either side, from just under the asphalt's edges (not under all of it, which would
  // fight it for the same pixels).
  const gravel = Coat.flat('#b5a98f');
  kit.root.add(Loose(strip(way, loopHalf - 0.1, loopHalf + 1.2, G - 0.012, (_) => 0), gravel));
  kit.root.add(Loose(strip(way, -loopHalf - 1.2, -loopHalf + 0.1, G - 0.012, (_) => 0), gravel));

  // The start line across the street, right in front of the office: where a lap starts and ends.
  kit.root.add(
    Loose(
      flatPlane(1.6, 7.6),
      const Coat.flat('#ffffff', canvas: Painted.checks),
      at: vm.Matrix4.translationValues(0, G - 0.004, streetZ),
    ),
  );

  var tunnel = (from: 0.0, to: 0.0);
  for (final s in stretch(ScenicPlace.tunnel)) {
    tunnel = s;
  }
  // Where the road crosses the creek: the bridge.
  final creekLine = smooth(creek, 8);
  var bridge = 0.0;
  var bridgeOff = double.infinity;
  for (final p in loop) {
    final d = distToLine(creekLine, p.x, p.z);
    if (d < bridgeOff) {
      bridgeOff = d;
      bridge = p.d;
    }
  }
  bool onBridge(double d) => (d - bridge).abs() < 9;

  // White posts with reflectors down both sides, and a guardrail on the mountain side of the pass.
  const post = Coat.plain('#f1f1ee');
  const reflector = Coat.glow('#ff9f1c', '#8a4b00');
  for (var d = 12.0; d < loopLength - 6; d += 22) {
    if ((d > tunnel.from - 6 && d < tunnel.to + 6) || onBridge(d)) continue;
    final i = indexAt(d);
    for (final side in const [-1, 1]) {
      final at = beside(i, side * (loopHalf + 1.7));
      kit.put(Stretch.road, box(0.14, 0.95, 0.14), post, x: at.x, y: G + 0.47, z: at.z);
      kit.put(Stretch.road, box(0.15, 0.13, 0.15), reflector, x: at.x, y: G + 0.8, z: at.z, shadow: false);
    }
  }
  const steel = Coat.plain('#c3c7cf');
  for (final s in stretch(ScenicPlace.mountains)) {
    for (var d = s.from + 4; d < s.to - 2; d += 4) {
      if (d > tunnel.from - 3 && d < tunnel.to + 3) continue;
      final a = beside(indexAt(d), loopHalf + 1.3);
      final b = beside(indexAt(d + 4), loopHalf + 1.3);
      kit.put(Stretch.mountains, box(0.14, 0.75, 0.14), steel, x: a.x, y: G + 0.37, z: a.z);
      final len = math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.z - a.z, 2));
      kit.put(
        Stretch.mountains,
        box(0.08, 0.32, len + 0.1),
        steel,
        x: (a.x + b.x) / 2,
        y: G + 0.62,
        z: (a.z + b.z) / 2,
        rot: yawQ(math.atan2(b.x - a.x, b.z - a.z)),
      );
    }
  }
  // Nothing grows on the road or its verges.
  for (var i = 0; i < loop.length; i += 3) {
    kit.take(loop[i].x, loop[i].z, loopPaved + 2.2);
  }
  return RoadInfo(roadU, creekLine, bridge);
}

/// A wooden sign on two posts, [text] on its face, facing [rotY] (its face toward +z turned by that).
void signpost(
  List<Clump> into,
  List<SignText> labels,
  double x,
  double z,
  double rotY,
  String text, [
  double width = 5,
]) {
  final g = Clump(x: x, y: G, z: z)..turn(rotY);
  const wood = Coat.plain('#7f5539');
  for (final sx in const [-1, 1]) {
    g.add(box(0.16, 3, 0.16), wood, x: sx * (width / 2 - 0.4), y: 1.5);
  }
  g.add(box(width, 1.4, 0.16), const Coat.plain('#dda15e'), y: 2.45);
  into.add(g);
  labels.add(
    SignText(
      text,
      const TextOpts(color: '#3d2b1f', size: 64),
      x: x + math.sin(rotY) * 0.09,
      y: G + 2.45,
      z: z + math.cos(rotY) * 0.09,
      rotY: rotY,
      scale: 1.9,
      fit: width - 0.4,
    ),
  );
}

/// The signs to the loop at the town's ends, and one at the start of each stretch.
void buildSigns(ScenicKit kit) {
  // A billboard across the street from the garage, and a sign at each end of the street.
  {
    final g = Clump(x: 24, y: G, z: 37)..turn(math.pi);
    const wood = Coat.plain('#5c4033');
    for (final sx in const [-1, 1]) {
      g.add(box(0.3, 5.6, 0.3), wood, x: sx * 3.2, y: 2.8);
    }
    g.add(box(8.4, 3.2, 0.25), const Coat.plain('#264653'), y: 4.1);
    kit.of(Stretch.meadow).add(g);
    kit.colliders.add(Collider(minX: 20.6, maxX: 27.4, minZ: 36.8, maxZ: 37.2, bottom: G, top: G + 5.6));
    kit.labels
      ..add(
        SignText(
          '🏎️ SCENIC LOOP',
          const TextOpts(color: '#ffd166', size: 72),
          x: 24,
          y: G + 4.75,
          z: 36.85,
          rotY: math.pi,
          scale: 1.35,
        ),
      )
      ..add(
        SignText(
          '🌾 farm · 🌲 pines · 🏔️ mountains · 🏖️ beach — 1.4 km, either way ⟷',
          const TextOpts(color: '#f1faee', size: 44),
          x: 24,
          y: G + 3.55,
          z: 36.85,
          rotY: math.pi,
          scale: double.infinity,
          fit: 7.8,
        ),
      );
  }
  signpost(kit.of(Stretch.meadow), kit.labels, streetEnd - 14, 20.2, -math.pi / 2, '🏔️ Scenic Loop ⟶', 4.6);
  signpost(kit.of(Stretch.meadow), kit.labels, -streetEnd + 14, 20.2, math.pi / 2, '⟵ Scenic Loop 🏖️', 4.6);

  // At the start of each stretch, a sign on the right (going round clockwise), facing the traffic.
  for (final place in const [
    ScenicPlace.farm,
    ScenicPlace.forest,
    ScenicPlace.mountains,
    ScenicPlace.beach,
    ScenicPlace.coast,
  ]) {
    final all = stretch(place);
    if (all.isEmpty) continue;
    final i = indexAt(all.first.from + 6);
    final p = loop[i];
    final at = beside(i, -(loopHalf + 3.4));
    signpost(
      kit.of(Stretch.road),
      kit.labels,
      at.x,
      at.z,
      math.atan2(-p.tx, -p.tz) - 0.3,
      '${place.icon} ${place.title}',
    );
    kit.take(at.x, at.z, 3);
  }
}
