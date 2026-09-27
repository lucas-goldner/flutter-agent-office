import 'dart:math' as math;

import 'package:office_shared/dog.dart';
import 'package:office_shared/protocol.dart';
import 'package:agent_office/world/character.dart';
import 'package:agent_office/world/dog.dart';
import 'package:agent_office/world/geo.dart';
import 'package:flutter_scene/scene.dart' show Node;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  group('reachCurve', () {
    test('is 0 outside the reach, 1 at full stretch', () {
      expect(reachCurve(-0.1), 0);
      expect(reachCurve(0), 0);
      expect(reachCurve(1), 0);
      expect(reachCurve(0.28), closeTo(1, 1e-9));
      expect(reachCurve(0.4), 1);
      expect(reachCurve(0.75), closeTo(0.5, 1e-9));
    });

    test('jabs out fast and eases back', () {
      expect(reachCurve(0.1), greaterThan(0.7));
      expect(reachCurve(0.9), lessThan(0.11));
    });
  });

  test('dragCurve: up, hold, down, rest', () {
    expect(dragCurve(0), 0);
    expect(dragCurve(0.35), closeTo(0.5, 1e-9));
    expect(dragCurve(1), 1);
    expect(dragCurve(2.0), closeTo(0.5, 1e-9));
    expect(dragCurve(kExhaleAt), 0);
    expect(dragCurve(kSmokeCycle - 0.1), 0);
  });

  group('workerBubble', () {
    test('says what the status is', () {
      expect(workerBubble(WorkerStatus.needsInput, true), (text: '❗ needs you', bg: '#ffd6e0'));
      expect(workerBubble(WorkerStatus.done, true), (text: '✅ done!', bg: '#caffbf'));
      expect(workerBubble(WorkerStatus.done, false), (text: '', bg: '#fffaf3'));
      expect(workerBubble(WorkerStatus.working, false), (text: '⌨️ working', bg: '#ffec99'));
      expect(workerBubble(WorkerStatus.exited, false).text, '💤');
      expect(workerBubble(WorkerStatus.idle, false).text, '');
    });

    test('every status has a bulb and a chip', () {
      for (final s in WorkerStatus.values) {
        expect(statusBulb[s], isNotNull, reason: '$s');
        expect(taskChip[s], isNotNull, reason: '$s');
      }
    });
  });

  group('euler', () {
    test('is three.js XYZ order: Rx * Ry * Rz', () {
      const x = 0.3, y = -1.1, z = 0.7;
      final m = vm.Matrix4.rotationX(x) * vm.Matrix4.rotationY(y) * vm.Matrix4.rotationZ(z) as vm.Matrix4;
      final q = euler(x, y, z);
      for (final v in [vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0), vm.Vector3(0.2, -0.5, 0.9)]) {
        // As the engine uses it: through a matrix (vm's Quaternion.rotated turns the other way).
        final a = vm.Matrix4.compose(vm.Vector3.zero(), q, vm.Vector3.all(1)).transform3(v.clone());
        final b = m.transform3(v.clone());
        expect((a - b).length, lessThan(1e-6));
      }
    });
  });

  group('geometry', () {
    // Each triangle faces the way its normals point (counter-clockwise from outside).
    void facesOut(GeoData g) {
      for (var t = 0; t < g.idx.length; t += 3) {
        final p = [for (final i in g.idx.sublist(t, t + 3)) vm.Vector3(g.p[i * 3], g.p[i * 3 + 1], g.p[i * 3 + 2])];
        final n = vm.Vector3(g.n[g.idx[t] * 3], g.n[g.idx[t] * 3 + 1], g.n[g.idx[t] * 3 + 2]);
        final face = (p[1] - p[0]).cross(p[2] - p[0]);
        expect(face.dot(n), greaterThan(-1e-9));
      }
    }

    test('primitives face out', () {
      facesOut(sphereData(0.5, 12, 8));
      facesOut(sphereData(0.355, 20, 12, 0, math.pi * 2, 0, math.pi * 0.45));
      facesOut(cylinderData(0.1, 0.2, 0.5, 8));
      facesOut(coneData(0.1, 0.3, 8));
      facesOut(capsuleData(0.26, 0.28, 6, 12));
      facesOut(torusData(0.06, 0.015, 6, 12, math.pi));
    });

    test("three's sphere: phi from -x round toward +z, a cap from the top", () {
      final cap = sphereData(1, 8, 4, 0, math.pi * 2, 0, math.pi * 0.45);
      final ys = [for (var i = 1; i < cap.p.length; i += 3) cap.p[i]];
      expect(ys.reduce(math.min), closeTo(math.cos(math.pi * 0.45), 1e-6));
      final s = sphereData(1, 4, 2);
      // Ring 1 (the equator), first vertex: phi = 0 at -x.
      expect(s.p.sublist(5 * 3, 5 * 3 + 3), [closeTo(-1, 1e-6), closeTo(0, 1e-6), closeTo(0, 1e-6)]);
      // phi = pi/2 is +z (the face, for hair).
      expect(s.p.sublist(6 * 3, 6 * 3 + 3), [closeTo(0, 1e-6), closeTo(0, 1e-6), closeTo(1, 1e-6)]);
    });

    test("three's torus arc lies in XY, from +x up toward +y", () {
      final t = torusData(1, 0.1, 4, 8, math.pi);
      for (var i = 0; i < t.count; i++) {
        expect(t.p[i * 3 + 1], greaterThan(-0.11));
      }
    });

    test('capsule spans length + 2 radius along y', () {
      final c = capsuleData(0.1, 0.22);
      final ys = [for (var i = 1; i < c.p.length; i += 3) c.p[i]];
      expect(ys.reduce(math.max), closeTo(0.21, 1e-9));
      expect(ys.reduce(math.min), closeTo(-0.21, 1e-9));
    });

    test('rotateX turns +y to +z, like geometry.rotateX(pi / 2)', () {
      final c = cylinderData(0.01, 0.01, 1, 4).rotateX(math.pi / 2);
      final zs = [for (var i = 2; i < c.p.length; i += 3) c.p[i]];
      expect(zs.reduce(math.max), closeTo(0.5, 1e-6));
    });
  });

  test('pointIn carries a point into another node\'s space', () {
    final world = Node()..localTransform = vm.Matrix4.diagonal3Values(1, 1, -1);
    final a = Node()..position = vm.Vector3(1, 2, 3);
    final b = Node()..position = vm.Vector3(0, 1, 0);
    world.add(a);
    a.add(b);
    final p = pointIn(world, b, vm.Vector3(0, 0, 1));
    expect((p - vm.Vector3(1, 3, 4)).length, lessThan(1e-6));
    final w = pointIn(null, b, vm.Vector3(0, 0, 1));
    expect((w - vm.Vector3(1, 3, -4)).length, lessThan(1e-6));
  });

  group('dog', () {
    test('moving is a walk; otherwise the act', () {
      expect(dogMotion(DogAct.nap, true), DogMotion.walk);
      for (final a in DogAct.values) {
        expect(dogMotion(a, false).name, a.name);
        expect(dogPoses[dogMotion(a, false)], isNotNull);
      }
    });

    test('poses ease toward their target', () {
      final p = dogPoses[DogMotion.stand]!.copy();
      for (var i = 0; i < 200; i++) {
        p.easeToward(dogPoses[DogMotion.nap]!, 1 - math.exp(-0.016 * 7));
      }
      expect(p.drop, closeTo(0.19, 1e-3));
      expect(p.eyes, closeTo(0, 1e-3));
      expect(p.front, closeTo(1.45, 1e-3));
    });

    test('front legs stretch to reach the floor sitting, not standing or lying', () {
      expect(frontReach(dogPoses[DogMotion.stand]!), closeTo(1, 1e-9));
      expect(frontReach(dogPoses[DogMotion.sit]!), greaterThan(1.3));
      expect(frontReach(dogPoses[DogMotion.lie]!), closeTo(1, 1e-9));
    });

    test('barks on schedule, picking up where it is on a late page', () {
      expect(barksBehind(-3), 0);
      expect(barksBehind(0.2), 0);
      expect(barksBehind(1), 1);
      expect(barksBehind(barkEveryS + 1.0), 2);
    });

    test('tail wags', () {
      expect(tailWag(DogMotion.nap), (0, 0));
      expect(tailWag(DogMotion.wag).$1, greaterThan(tailWag(DogMotion.walk).$1));
      expect(tailWag(DogMotion.bark), (8, 0.35));
    });
  });
}
