import 'dart:math' as math;

import 'package:agent_office/world/golf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';

void main() {
  final street = streetBelow(0);

  test('the same shot always goes the same way', () {
    final a = fly((yaw: pinYaw, loft: 0.7, power: 0.8), street, 0);
    final b = fly((yaw: pinYaw, loft: 0.7, power: 0.8), street, 0);
    expect(a.path, b.path);
    expect(a.lie, b.lie);
  });

  test('a good shot at the pin comes down near it, on the street', () {
    var best = double.infinity;
    for (var p = 0.3; p <= 1.0; p += 0.01) {
      final f = fly((yaw: pinYaw, loft: 42 * math.pi / 180, power: p), street, 0);
      if (f.fromPin.isFinite && f.fromPin < best) best = f.fromPin;
    }
    expect(best, lessThan(4));
    expect(pinDistance, closeTo(43, 1.5));
  });

  test('a flat, soft one doesn’t clear the railing', () {
    final f = fly((yaw: pinYaw, loft: loftMin, power: 0.15), street, 0);
    expect(f.lie, Lie.deck);
    expect(f.fromPin.isNaN, isTrue);
    expect(f.hits.any((h) => h.kind == HitKind.rail), isTrue);
    expect(lieText(f), "Didn't clear the railing");
  });

  test('shots are held to the lofts and aims there are', () {
    final f = fly((yaw: 5, loft: 2, power: 3), street, 0);
    expect(f.shot.yaw, aimMax);
    expect(f.shot.loft, loftMax);
    expect(f.shot.power, 1);
  });

  test('what lies where', () {
    expect(lieAt(GolfHole.x, GolfHole.z), Lie.green);
    expect(lieAt(GolfHole.x, (Road.minZ + Road.maxZ) / 2), Lie.road);
    expect(lieAt(GolfHole.x - 5.4, GolfHole.z - 4.4), Lie.sand);
    expect(lieAt(150, 150), Lie.rough);
  });

  test('distances read out', () {
    expect(pinText(0.4), '40 cm');
    expect(pinText(3.42), '3.4 m');
    expect(pinText(27.4), '27 m');
  });

  test('you stand square to the line, the hole on your left', () {
    final s = stance(0);
    expect(s.x, closeTo(GolfTee.ball.x + 0.57, 1e-9));
    expect(s.facing, closeTo(-math.pi / 2, 1e-9));
  });

  test('the flight is played back along its path', () {
    final f = fly((yaw: pinYaw, loft: 0.7, power: 0.8), street, 0);
    expect(f.at(0).x, closeTo(teeBall.x, 1e-4));
    expect(f.at(f.seconds).distanceTo(f.rest), lessThan(1e-3));
  });
}
