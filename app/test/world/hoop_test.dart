import 'dart:math' as math;

import 'package:agent_office/world/hoop.dart';
import 'package:agent_office/world/office/office_colliders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/hoop.dart';

BallThrow shotFrom(double x, double z, [double y = 2]) {
  final from = (x: x, y: y, z: z);
  final pitch = underCeiling(from, throwPitch(lookAtRim(from)));
  final v = idealSpeed(from, pitch)!;
  final heading = math.atan2(Hoop.rim.x - x, Hoop.rim.z - z);
  return (
    x: x,
    y: y,
    z: z,
    vx: math.sin(heading) * math.cos(pitch) * v,
    vy: math.sin(pitch) * v,
    vz: math.cos(heading) * math.cos(pitch) * v,
  );
}

void main() {
  List<Solid> solids() => solidsOf(officeColliders());

  test('a shot at the ideal speed from the free-throw line goes in', () {
    final t = BallTracker(solids);
    Basket? made;
    t.onBasket = (b) => made = b;
    t.throwNow(shotFrom(Hoop.face + Hoop.line, Hoop.z), 'me', 0);
    for (var ms = 0.0; ms < 4000; ms += 16) {
      t.update(ms);
    }
    expect(made, isNotNull);
    expect(made!.by, 'me');
    expect(made!.three, isFalse);
    expect(made!.distance, closeTo(Hoop.line - 0.4, 0.01));
  });

  test('a throw nowhere near the hoop is a miss, and the ball ends up lying still', () {
    final t = BallTracker(solids);
    String? missed;
    t.onMiss = (by) => missed = by;
    t.throwNow((x: 0, y: 1.5, z: 0, vx: 2, vy: 1, vz: 0), 'me', 0);
    for (var ms = 0.0; ms < 30000; ms += 50) {
      t.update(ms);
    }
    expect(missed, 'me');
    expect(t.still, isTrue);
  });

  test('the office’s word on a throw catches up with it quietly', () {
    final t = BallTracker(solids);
    var thrown = '';
    t.onThrow = (by) => thrown = by;
    final s = shotFrom(Hoop.face + 5, Hoop.z + 1);
    t.set(
      BallState(
        shot: BallShot(x: s.x, y: s.y, z: s.z, vx: s.vx, vy: s.vy, vz: s.vz, by: 'ada', elapsed: 10000),
      ),
      20000,
    );
    // Ten seconds in, the throw is long over: nobody sees it thrown.
    expect(thrown, '');
    t.update(20016);
    expect(t.at.y, lessThan(1));
  });

  test('taking it, and the office saying someone has it, puts it in their hands', () {
    final t = BallTracker(solids);
    t.takeNow('me');
    expect(t.holder, 'me');
    expect(t.still, isFalse);
    t.set(const BallState(holder: 'ada'), 0);
    expect(t.holder, 'ada');
    t.set(const BallState(), 0);
    expect(t.holder, isNull);
    t.update(0);
    expect(t.at.x, closeTo(Ball.home.x, 1e-4));
  });
}
