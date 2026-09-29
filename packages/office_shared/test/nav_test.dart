// Port of tests/nav.test.ts.
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('a worker sent home walks round the furniture, out the exit door and off along the sidewalk', () {
    for (final seat in [...seats, ...stations, ...meetingSeats]) {
      final way = wayHome(seat);
      // It hops down right beside where it sat.
      expect(
        math.sqrt(math.pow(way[0].$1 - seat.x, 2) + math.pow(way[0].$2 - seat.z, 2)),
        lessThan(1.2),
        reason: '${seat.id} hops down beside its seat',
      );
      final out = way.indexWhere((p) => p.$1 < Floor.minX);
      expect(out, greaterThan(1), reason: '${seat.id} leaves by the exit');
      // From the aisle to the door, every step is on open floor.
      for (var i = 2; i < out; i++) {
        final (x0, z0) = way[i - 1];
        final (x1, z1) = way[i];
        final n = (math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0)) / 0.2).ceil();
        for (var k = 0; k <= n; k++) {
          final x = x0 + ((x1 - x0) * k) / n;
          final z = z0 + ((z1 - z0) * k) / n;
          expect(
            walkable(x, z),
            isTrue,
            reason: '${seat.id} walks into something at (${x.toStringAsFixed(2)}, ${z.toStringAsFixed(2)})',
          );
        }
      }
      // Through the doorway, not the wall beside it.
      for (final (_, z) in [way[out - 1], way[out]]) {
        expect((z - exitDoor.u).abs(), lessThan(exitDoor.width / 2 - 0.2), reason: '${seat.id} goes through the door');
      }
      // Down the steps outside, then away along the sidewalk.
      expect(
        way.sublist(out).every((p) => p.$1 < ExitStairs.minX + 1 || p.$2 > Road.minZ - 2.1),
        isTrue,
        reason: '${seat.id} stays off the building',
      );
      final (ex, ez) = way.last;
      expect(
        ez > Road.minZ - 2 && ez < Road.minZ && ex < ExitStairs.minX - 10,
        isTrue,
        reason: '${seat.id} ends up down the sidewalk',
      );
    }
  });

  void expectPts(List<Pt> actual, List<List<double>> expected) {
    expect(actual.length, expected.length, reason: '$actual');
    for (var i = 0; i < expected.length; i++) {
      expect(actual[i].$1, closeTo(expected[i][0], 1e-9));
      expect(actual[i].$2, closeTo(expected[i][1], 1e-9));
    }
  }

  test('route matches the TS corners across the room', () {
    // (15, 10) is under the meeting table now: the route ends at the nearest open cell to it.
    // Expected values from running src/shared/nav.ts.
    expectPts(route((-15, -10), (15, 10)), [
      [-15, -10],
      [-14.25, -8.75],
      [-7.25, -5.25],
      [7.25, 7.25],
      [10.25, 7.25],
      [10.75, 8.25],
      [10.75, 8.75],
      [15.75, 8.75],
      [15.75, 9.25],
    ]);
  });

  test('route stays on open floor and keeps its ends', () {
    final r = route((-15, -10), (15, -5));
    expect(r.first, (-15.0, -10.0));
    expect(r.last, (15.0, -5.0));
    for (final (x, z) in r.skip(1).take(r.length - 2)) {
      expect(walkable(x, z), isTrue);
    }
  });

  test('wayHome matches the TS for a desk and a bean bag', () {
    expectPts(wayHome(desks[0]), [
      [-12.299999999999999, -5.5],
      [-12.299999999999999, -6.3],
      [-13.25, -5.25],
      [-14.75, 4.25],
      [-17.25, 6.25],
      [-19.1, 6.5],
      [-19.1, 12.860000000000001],
      [-19.1, 21.3],
      [-38, 21.3],
    ]);
    expectPts(wayHome(beanbags[3]), [
      [-16, -1.95],
      [-14.850000000000001, -1.95],
      [-14.75, 4.25],
      [-17.25, 6.25],
      [-19.1, 6.5],
      [-19.1, 12.860000000000001],
      [-19.1, 21.3],
      [-38, 21.3],
    ]);
  });

  test('wayIn and wayToBalcony match the TS', () {
    expectPts(wayIn(meetingSeats[0]), [
      [8.5, -10.1],
      [9.75, 6.25],
      [10.75, 8.25],
      [10.849999999999998, 9.850000000000001],
      [11.299999999999999, 9.850000000000001],
    ]);
    expectPts(wayToBalcony(stations[2]), [
      [-6.85, -12.25],
      [-6.85, -10.7],
      [-6.75, 1.75],
      [-4.25, 12.25],
      [-4, 13.700000000000001],
      [-4, 16.25],
    ]);
  });

  double hypot(double a, double b) => math.sqrt(a * a + b * b);

  /// Every step from a to b is on open floor.
  void clear(Pt a, Pt b, String what) {
    final n = (hypot(b.$1 - a.$1, b.$2 - a.$2) / 0.2).ceil();
    for (var k = 0; k <= n; k++) {
      final x = a.$1 + ((b.$1 - a.$1) * k) / n;
      final z = a.$2 + ((b.$2 - a.$2) * k) / n;
      expect(
        walkable(x, z),
        isTrue,
        reason: '$what walks into something at (${x.toStringAsFixed(2)}, ${z.toStringAsFixed(2)})',
      );
    }
  }

  test(
    'a worker called to a meeting walks from the elevator, in through the meeting room door, to beside its chair',
    () {
      for (final seat in meetingSeats) {
        final way = wayIn(seat);
        final (x0, z0) = way[0];
        expect(
          (x0 - Elevator.x).abs() < 0.6 && z0 > elevatorFront && z0 < elevatorFront + 1.2,
          isTrue,
          reason: '${seat.id} steps out of the elevator',
        );
        // It ends beside its chair, and gets there on open floor.
        final (ex, ez) = way.last;
        expect(hypot(ex - seat.x, ez - seat.z), lessThan(1.3), reason: '${seat.id} ends beside its chair');
        for (var i = 1; i < way.length - 1; i++) {
          clear(way[i - 1], way[i], seat.id);
        }
        // Into the room through its doorway, not the glass.
        final crossing = [
          for (var i = 0; i < way.length; i++) i,
        ].indexWhere((i) => i > 0 && way[i - 1].$2 < MeetingRoom.minZ && way[i].$2 >= MeetingRoom.minZ);
        expect(crossing, greaterThan(0), reason: '${seat.id} goes into the room');
        final (ax, az) = way[crossing - 1];
        final (bx, bz) = way[crossing];
        final x = ax + ((bx - ax) * (MeetingRoom.minZ - az)) / (bz - az);
        expect(
          x > MeetingRoom.door.x0 && x < MeetingRoom.door.x1,
          isTrue,
          reason: '${seat.id} goes in by the door (x ${x.toStringAsFixed(2)})',
        );
      }
    },
  );

  test('upstairs, with no exit door, a worker sent home walks out onto the balcony to the railing', () {
    for (final seat in [...seats, ...stations, ...meetingSeats]) {
      final way = wayToBalcony(seat);
      expect(
        hypot(way[0].$1 - seat.x, way[0].$2 - seat.z),
        lessThan(1.2),
        reason: '${seat.id} hops down beside its seat',
      );
      final out = way.indexWhere((p) => p.$2 > Floor.maxZ);
      expect(out, greaterThan(1), reason: '${seat.id} goes out onto the balcony');
      for (var i = 2; i < out; i++) {
        clear(way[i - 1], way[i], seat.id);
      }
      // Through the balcony doors, then straight across to the railing.
      for (final (x, _) in way.sublist(out - 1)) {
        expect(
          (x - balconyDoor.u).abs(),
          lessThan(balconyDoor.width / 2 - 0.3),
          reason: '${seat.id} goes through the balcony doors',
        );
      }
      final (jx, jz) = way.last;
      expect([jx, jz], [Parachute.jump.x, Parachute.jump.z]);
      expect(jz < Balcony.maxZ && jz > Balcony.maxZ - 0.6, isTrue, reason: '${seat.id} ends up at the railing');
    }
  });

  test('nearestWalkable leaves open floor alone and moves off furniture', () {
    expect(nearestWalkable((0.0, 0.0)), (0.0, 0.0));
    final d = desks[0];
    final p = nearestWalkable((d.x, d.z));
    expect(walkable(p.$1, p.$2), isTrue);
  });
}
