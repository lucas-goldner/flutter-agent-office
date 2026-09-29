import 'dart:math' as math;

import 'package:agent_office/ui/compass.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  const size = Size(1000, 800);
  final cam = PerspectiveCamera(
    position: vm.Vector3(0, 0, 0),
    target: vm.Vector3(0, 0, 1),
    fovRadiansY: math.pi / 3,
    fovNear: 0.1,
    fovFar: 100,
  );

  test('a worker in view gets no arrow; one off to a side or behind does', () {
    expect(bearingFrom(cam, vm.Vector3(0, 0, 5), size), isNull);
    final side = bearingFrom(cam, vm.Vector3(20, 0, 2), size)!;
    final other = bearingFrom(cam, vm.Vector3(-20, 0, 2), size)!;
    expect(side.dx.sign, -other.dx.sign);
    // Behind and to the same side still points that way.
    final behind = bearingFrom(cam, vm.Vector3(20, 0, -5), size)!;
    expect(behind.dx.sign, side.dx.sign);
    // Straight behind: down.
    expect(bearingFrom(cam, vm.Vector3(0, 0, -5), size), const Offset(0, 1));
  });

  test('marks go to the edge of the box, the way they point', () {
    final box = compassBox(size);
    final m = placeMarks(
      [('r', const Offset(10, 0)), ('u', const Offset(0, -3)), ('d', const Offset(0, 1))],
      size,
      box,
    );
    expect(m.map((p) => (p.id, p.edge)), [('r', CompassEdge.right), ('u', CompassEdge.top), ('d', CompassEdge.bottom)]);
    expect(m[0].x, box.right);
    expect(m[0].y, size.height / 2);
    expect(m[1].y, box.top);
    expect(m[0].angle, 0);
    expect(m[2].angle, closeTo(math.pi / 2, 1e-9));
  });

  test('marks on one edge spread out, and stay inside it', () {
    final box = compassBox(size);
    final same = placeMarks([for (var i = 0; i < 3; i++) ('w$i', const Offset(1, 0))], size, box);
    final ys = same.map((p) => p.y).toList();
    expect(ys[1] - ys[0], greaterThanOrEqualTo(56));
    expect(ys[2] - ys[1], greaterThanOrEqualTo(56));
    final low = placeMarks([for (var i = 0; i < 12; i++) ('w$i', const Offset(1, 0.3))], size, box);
    expect(low.last.y, lessThanOrEqualTo(box.bottom));
    expect(low.first.y, greaterThanOrEqualTo(box.top));
  });
}
