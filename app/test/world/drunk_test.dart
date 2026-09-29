import 'dart:math' as math;

import 'package:agent_office/world/drunk.dart';
import 'package:agent_office/world/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart' show Floor;
import 'package:agent_office/world/collider.dart';

void main() {
  test('sober, nothing sways, staggers or blurs', () {
    for (final t in [0.0, 1.3, 77.0]) {
      final s = drunkSway(0, t);
      expect([s.roll, s.pitch, s.yaw], [0, 0, 0]);
      expect(drunkStagger(0, t), 0);
    }
    expect(DrunkLook.at(0, 5).isSober, isTrue);
    expect(identical(DrunkLook.at(0.005, 5), DrunkLook.sober), isTrue);
  });

  test('drunk, the view rolls and sways more the more you have had, within reason', () {
    var most = 0.0;
    for (var t = 0.0; t < 60; t += 0.1) {
      final a = drunkSway(0.5, t), b = drunkSway(1.0, t);
      expect(b.roll.abs(), closeTo(a.roll.abs() * 2, 1e-12));
      expect(b.roll.abs(), lessThan(0.1));
      expect(b.pitch.abs(), lessThanOrEqualTo(0.03));
      expect(drunkStagger(1, t).abs(), lessThan(0.63));
      most = math.max(most, b.roll.abs());
    }
    expect(most, greaterThan(0.05));
  });

  test('the screen blurs, breathes and warms with how drunk you are, and holds still if asked', () {
    final tipsy = DrunkLook.at(0.3, 2), wasted = DrunkLook.at(1.5, 2);
    expect(wasted.blur, greaterThan(tipsy.blur));
    expect(wasted.warmth, 1);
    expect(tipsy.warmth, closeTo(0.3, 1e-9));
    final still = DrunkLook.at(1, 10, motion: false), still2 = DrunkLook.at(1, 20, motion: false);
    expect(still.scale, still2.scale);
    expect(still.dx, still2.dx);
  });

  test('the colour grade is the identity when sober', () {
    expect(drunkColorMatrix(0), [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0]);
    final m = drunkColorMatrix(1);
    // Warmer: more red than blue on white.
    expect(m[0] + m[1] + m[2], greaterThan(m[10] + m[11] + m[12]));
  });

  test('drunk, your feet wander off the way you meant to walk', () {
    final floor = [
      Collider(minX: Floor.minX, maxX: Floor.maxX, minZ: Floor.minZ, maxZ: Floor.maxZ, top: 0, bottom: -0.3),
    ];
    PlayerController walk(double drunk) {
      final p = PlayerController(floor)
        ..drunk = drunk
        ..camYaw = 0;
      p.input.forward = true;
      for (var i = 0; i < 30; i++) {
        p.update(1 / 30);
      }
      return p;
    }

    final sober = walk(0), drunk = walk(1.2);
    expect(sober.pos.x.abs(), lessThan(1e-9));
    expect(drunk.pos.x.abs(), greaterThan(0.01));
    expect(drunk.roll, isNot(0));
    expect(sober.roll, 0);
  });
}
