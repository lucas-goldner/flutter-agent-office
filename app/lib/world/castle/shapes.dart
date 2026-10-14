// The shapes the hall is cut from: pointed arches (for the arcade, the doorway and the windows), and
// rods. A port of world/castle/shapes.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../office/geo.dart' show Shape2, extrudeShape, transformed;
import '../toon.dart' show mesh;
import 'kit.dart' show flatShape;
import '../office/geo.dart' show cyl;

/// A pointed arch's outline, [span] across at its feet (y 0), made of two arcs of radius [r] (at
/// least span / 2; the bigger, the pointier), grown outward by [grow].
void archPath(Shape2 shape, double span, double r, double grow, [bool reverse = false]) {
  final cxL = -span / 2 + r;
  final cxR = span / 2 - r;
  final big = r + grow;
  // Where the left arc (round its center right of the middle) reaches the middle, at the point.
  final apex = math.acos((span / 2 - r) / big);
  if (!reverse) {
    // Up the left arc from its foot to the point, then down the right one to its foot.
    shape.absarc(cxL, 0, big, math.pi, apex, true);
    shape.absarc(cxR, 0, big, math.pi - apex, 0, true);
  } else {
    shape.absarc(cxR, 0, big, 0, math.pi - apex, false);
    shape.absarc(cxL, 0, big, apex, math.pi, false);
  }
}

/// The apex height of a pointed arch (see [archPath]).
double archRise(double span, double r, [double grow = 0]) {
  final d = r - span / 2;
  return math.sqrt(math.max(0, math.pow(r + grow, 2) - d * d));
}

Geometry _centred(Shape2 s, double depth) =>
    transformed(extrudeShape(s, depth), vm.Matrix4.translationValues(0, 0, -depth / 2));

/// A band of stone following a pointed arch: [span] wide inside, [band] thick, [depth] deep (along z), feet at y 0.
Geometry archBand(double span, double band, double depth, [double? r]) {
  r ??= span * 0.8;
  final s = Shape2(10)..moveTo(-span / 2 - band, 0);
  archPath(s, span, r, band);
  s.lineTo(span / 2, 0);
  archPath(s, span, r, 0, true);
  s.lineTo(-span / 2 - band, 0);
  return _centred(s, depth);
}

/// A slab [width] wide and [height] high with a pointed arch [span] wide cut out of its foot: the stone over a doorway.
Geometry archFill(double width, double height, double span, double depth, double r) {
  final s = Shape2(10)
    ..moveTo(-width / 2, 0)
    ..lineTo(-span / 2, 0);
  archPath(s, span, r, 0);
  s
    ..lineTo(width / 2, 0)
    ..lineTo(width / 2, height)
    ..lineTo(-width / 2, height)
    ..lineTo(-width / 2, 0);
  return _centred(s, depth);
}

/// The outline of a pointed-arch window [w] wide and [h] high to its point, bottom left first.
List<vm.Vector2> archOutline(double w, double h) {
  final r = w * 0.85;
  final rise = archRise(w, r);
  final top = Shape2(5)..moveTo(-w / 2, 0);
  archPath(top, w, r, 0);
  return [
    vm.Vector2(-w / 2, 0),
    vm.Vector2(-w / 2, h - rise),
    for (final v in top.points.skip(1)) vm.Vector2(v.x, v.y + h - rise),
    vm.Vector2(w / 2, 0),
  ];
}

/// A flat pointed-arch window pane, [w] wide and [h] high to its point, with UVs over its bounding box.
Geometry archPane(double w, double h) => flatShape(archOutline(w, h), uvOf: (p) => ((p.x + w / 2) / w, p.y / h));

/// A thin rod from [a] to [b] (a chain, a pole).
Node rod(vm.Vector3 a, vm.Vector3 b, double r, Material mat) {
  final along = b - a;
  final m = mesh(cyl(r, r, along.length, 5), mat, (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2, false);
  m.rotation = vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), along.normalized());
  return m;
}
