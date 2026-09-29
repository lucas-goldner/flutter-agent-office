// Port of tests/hoop.test.ts: the shared half. The court (server/court.ts) is the server's.
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

// The floor, the wall behind the hoop, the ceiling and the backboard: all a shot at the hoop meets.
final room = [
  const Solid(minX: Floor.minX, maxX: Floor.maxX, minZ: Floor.minZ, maxZ: Floor.maxZ, bottom: -0.3, top: 0),
  const Solid(minX: Floor.minX - 0.3, maxX: Floor.minX, minZ: Floor.minZ, maxZ: Floor.maxZ, top: 99),
  const Solid(
    minX: Floor.minX,
    maxX: Floor.maxX,
    minZ: Floor.minZ,
    maxZ: Floor.maxZ,
    bottom: wallHeight,
    top: wallHeight + 0.3,
  ),
  backboard(),
];

/// A shot from [dist] meters straight out from the rim, let go of at [power] on the meter.
BallSim shoot(double dist, double power, [List<BallHit>? hits]) {
  final from = (x: Hoop.rim.x + dist, y: 1.4, z: Hoop.z);
  final pitch = underCeiling(from, throwPitch(lookAtRim(from)));
  final v = shotSpeed(idealSpeed(from, pitch)!, power);
  final s = launchBall((x: from.x, y: from.y, z: from.z, vx: -v * math.cos(pitch), vy: v * math.sin(pitch), vz: 0));
  simulate(s, 30, room, hits);
  return s;
}

void main() {
  test('a shot let go of right in the sweet spot drops through the ring, from close up to way out', () {
    for (final dist in [2.0, 4.2, 6, 9, 12, 15]) {
      final hits = <BallHit>[];
      final s = shoot(dist.toDouble(), Sweet.at, hits);
      expect(s.scored, isTrue, reason: 'from $dist m');
      expect(!s.touchedRim && !s.touchedBoard, isTrue, reason: 'nothing but net from $dist m');
      expect(hits.where((h) => h.kind == BallHitKind.score).length, 1, reason: 'it goes in once');
    }
  });

  test('well short of the sweet spot, or at the top of the meter, misses (close in, a long one can still bank in)', () {
    for (final dist in [4.2, 8.0]) {
      expect(shoot(dist, Sweet.at - 0.25).scored, isFalse, reason: 'short from $dist m');
    }
    for (final dist in [8.0, 12.0]) {
      expect(shoot(dist, 1).scored, isFalse, reason: 'long from $dist m');
    }
  });

  test('a long shot stays under the ceiling', () {
    final from = (x: Hoop.rim.x + 15.5, y: 1.4, z: Hoop.z);
    final pitch = underCeiling(from, throwPitch(lookAtRim(from)));
    final v = idealSpeed(from, pitch)!;
    expect(from.y + math.pow(v * math.sin(pitch), 2) / 19.6, lessThan(wallHeight - Ball.r));
  });

  test('the same throw flies exactly the same way every time, so every page sees the same shot', () {
    final a = shoot(7, 0.71);
    final b = shoot(7, 0.71);
    expect([a.x, a.y, a.z, a.t, a.scored], [b.x, b.y, b.z, b.t, b.scored]);
  });

  test('a dropped ball bounces, rolls to a stop on the floor and can be picked up there', () {
    final s = launchBall((x: 0, y: 1.2, z: 0, vx: 1, vy: 0.5, vz: 0));
    simulate(s, 30, room);
    expect(s.still && !s.lost, isTrue);
    expect((s.y - Ball.r).abs(), lessThan(0.01), reason: 'on the floor (${s.y})');
    expect(outOfReach(s.x, s.y, s.z), isFalse);
  });

  test('up on something tall it is out of reach, but not up in the loft', () {
    expect(outOfReach(5.4, 3.05 + Ball.r, -5.4), isTrue, reason: 'on top of the whiteboard');
    const lx = (Loft.minX + Loft.maxX) / 2, lz = (Loft.minZ + Loft.maxZ) / 2;
    expect(outOfReach(lx, Loft.y + Ball.r, lz), isFalse, reason: 'on the loft floor');
    expect(outOfReach(lx, Loft.y + Loft.height + 0.2 + Ball.r, lz), isTrue, reason: 'on the loft roof');
  });

  test('the meter runs up to the top and back down', () {
    expect(meter(0), 0);
    expect(meter(0.5) > 0.4 && meter(0.5) < 0.6, isTrue);
    expect((meter(1.05) - 1).abs(), lessThan(1e-9));
    expect((meter(1.575) - 0.5).abs(), lessThan(1e-9));
    expect(meter(2.1).abs(), lessThan(1e-9));
  });

  test('the office only passes on throws from inside the building, no faster than anyone throws', () {
    const ok = (x: -12.0, y: 1.4, z: 10.0, vx: -5.0, vy: 5.0, vz: 0.0);
    expect(throwOk(ok), isTrue);
    expect(throwOk((x: ok.x, y: ok.y, z: ok.z, vx: -Ball.maxSpeed, vy: 5, vz: 0)), isFalse, reason: 'too fast');
    expect(
      throwOk((x: double.nan, y: ok.y, z: ok.z, vx: ok.vx, vy: ok.vy, vz: ok.vz)),
      isFalse,
      reason: 'not a number',
    );
    expect(throwOk((x: 60, y: ok.y, z: ok.z, vx: ok.vx, vy: ok.vy, vz: ok.vz)), isFalse, reason: 'out in the street');
  });

  test('the ball on the wire: held, thrown, or home', () {
    for (final j in [
      <String, dynamic>{},
      {'holder': 'p1'},
      {
        'shot': {'x': -12.0, 'y': 1.4, 'z': 10.0, 'vx': -5.0, 'vy': 6.0, 'vz': 0.0, 'by': 'ann', 'elapsed': 400},
      },
    ]) {
      expect(BallState.fromJson(j).toJson(), j);
    }
  });
}
