// tests/driving.test.ts: a real Fleet on the street, a real PlayerController in it, and the Driver
// at the wheel: off down the road, into a column and out again, along a wall, out by the door, along
// for the ride, and round the scenic loop flat out with a lap timed.

import 'dart:math' as math;

import 'package:agent_office/office/driving.dart';
import 'package:agent_office/office/laps.dart';
import 'package:agent_office/world/collider.dart';
import 'package:agent_office/world/office/fleet.dart';
import 'package:agent_office/world/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/garage.dart';
import 'package:office_shared/layout.dart' show Road, streetY;
import 'package:office_shared/scenic.dart' show loopLength, nearLoop, streetEnd;

const double _g = streetY;
const double _roadZ = (Road.minZ + Road.maxZ) / 2;

/// The Blue Lambo, moved out onto the road for these.
const int _blue = 8;

class _Street {
  _Street([List<Collider> solids = const []]) {
    colliders.addAll([Collider(minX: -400, maxX: 400, minZ: -400, maxZ: 600, bottom: _g - 1, top: _g), ...solids]);
    fleet = Fleet(colliders, <Interactable>[]);
    player = PlayerController(colliders)..view = ViewMode.third;
    driver = Driver(player, fleet, DriveHooks(moved: (_, p) => sent.add(p), bump: (_, speed) => bumps.add(speed)));
    fleet.place(_blue, const CarPose(x: 0, z: _roadZ, rotY: math.pi / 2));
  }

  final List<Collider> colliders = [];
  late final Fleet fleet;
  late final PlayerController player;
  late final Driver driver;
  final List<CarPose> sent = [];
  final List<double> bumps = [];

  void keys(Set<String> held) => player.input
    ..forward = held.contains('W')
    ..back = held.contains('S')
    ..left = held.contains('A')
    ..right = held.contains('D')
    ..jump = held.contains('Space');

  void frames(int n) {
    for (var i = 0; i < n; i++) {
      player.update(1 / 60);
    }
  }

  LivePose get car => fleet.views[_blue].pose;
}

Collider _box(double x, double z, double w, double d) =>
    Collider(minX: x - w / 2, maxX: x + w / 2, minZ: z - d / 2, maxZ: z + d / 2, bottom: _g, top: _g + 3);

void main() {
  test('behind the wheel, W drives off down the road, with you in your seat and the office told where', () {
    final s = _Street();
    s.driver.enter(_blue, CarSeat.driver);
    s.keys({'W'});
    s.frames(90);
    final car = s.car;
    expect(car.x, greaterThan(5), reason: 'east along the road');
    expect((car.z - _roadZ).abs(), lessThan(1e-6));
    final seat = carPoint(car.at, carSeats[CarSeat.driver]!.x, carSeats[CarSeat.driver]!.z);
    expect(math.sqrt(math.pow(s.player.pos.x - seat.x, 2) + math.pow(s.player.pos.z - seat.z, 2)), lessThan(1e-4));
    expect(s.player.pos.y, closeTo(_g, 1e-6), reason: 'sitting in it');
    expect(s.sent.length, inInclusiveRange(6, 29), reason: 'a few times a second, not every frame');
  });

  test('a column in the way stops the car short with a crunch, and it backs away from it', () {
    final s = _Street([_box(12, _roadZ, 0.5, 0.5)]);
    s.driver.enter(_blue, CarSeat.driver);
    s.keys({'W'});
    s.frames(240);
    expect(s.car.x + Car.length / 2, lessThanOrEqualTo(11.75 + 1e-6), reason: 'stopped at the column');
    expect(s.bumps, isNotEmpty);
    expect(s.bumps.first, greaterThan(5), reason: 'a crunch');
    s.keys({'S'});
    s.frames(60);
    expect(s.car.x, lessThan(8), reason: 'reversing out of it');
  });

  test('at an angle into a wall, the car slides along it rather than stopping dead', () {
    // A wall along the road's north edge; the car heads east, veering into it.
    final wall = Collider(minX: -80, maxX: 80, minZ: Road.minZ - 1, maxZ: Road.minZ + 0.3, bottom: _g, top: _g + 3);
    final s = _Street([wall]);
    s.fleet.place(_blue, const CarPose(x: 0, z: Road.minZ + 2.5, rotY: math.pi / 2 + 0.35, speed: 12));
    s.driver.enter(_blue, CarSeat.driver);
    s.keys({'W'});
    s.frames(60);
    final car = s.car;
    expect(car.x, greaterThan(10), reason: 'on along the wall');
    expect(car.speed, greaterThan(10));
    expect((car.rotY - math.pi / 2).abs(), lessThan(0.05), reason: 'turned to run along it');
    for (final (sx, sz) in const [(1, 1), (-1, 1), (1, -1), (-1, -1)]) {
      final c = carPoint(car.at, sx * Car.width / 2, sz * Car.length / 2);
      expect(c.z, greaterThanOrEqualTo(wall.maxZ - 1e-6), reason: 'not into it');
    }
  });

  test('E gets you out by your door, the car stopped; with no room anywhere round it, you stay in', () {
    final s = _Street();
    s.driver.enter(_blue, CarSeat.driver);
    s.keys({'W'});
    s.frames(30);
    s.keys({});
    expect(s.driver.leave(), isTrue);
    expect(s.driver.active, isFalse);
    expect(s.player.rig, isNull);
    expect(s.sent.last.speed, 0, reason: 'parked where you left it');
    // The driver's side is the car's left: north, heading east.
    expect(s.player.pos.z, lessThan(s.car.z - Car.width / 2 - 0.3), reason: 'out on the driver’s side');
    // Hemmed in on every side.
    final c = s.car;
    s.colliders.addAll([
      _box(c.x, c.z - 1.85, 8, 0.6),
      _box(c.x, c.z + 1.85, 8, 0.6),
      _box(c.x - 3, c.z, 0.6, 4),
      _box(c.x + 3, c.z, 0.6, 4),
    ]);
    s.driver.enter(_blue, CarSeat.driver);
    expect(s.driver.leave(), isFalse, reason: 'no room to open a door');
    expect(s.driver.active, isTrue);
    expect(s.driver.leave(true), isTrue, reason: 'unless you have to (another floor, a desk)');
  });

  test("beside the driver, you ride along but don't drive", () {
    final s = _Street();
    s.driver.enter(_blue, CarSeat.passenger);
    s.keys({'W', 'A'});
    s.frames(60);
    expect(s.car.x, 0);
    expect(s.sent, isEmpty);
    // Someone else drives it on: you go with it.
    s.fleet.place(_blue, CarPose(x: 10, z: s.car.z, rotY: s.car.rotY));
    s.frames(1);
    final seat = carPoint(s.car.at, carSeats[CarSeat.passenger]!.x, carSeats[CarSeat.passenger]!.z);
    expect(math.sqrt(math.pow(s.player.pos.x - seat.x, 2) + math.pow(s.player.pos.z - seat.z, 2)), lessThan(1e-4));
  });

  test("flat out with no hands, the car rides the scenic loop's edges all the way round, and the lap is timed", () {
    final s = _Street();
    s.fleet.place(_blue, const CarPose(x: -20, z: _roadZ, rotY: math.pi / 2));
    s.driver.enter(_blue, CarSeat.driver);
    s.keys({'W'});
    final laps = LapTimer();
    double? lap;
    var furthest = 0.0;
    var slowest = double.infinity;
    for (var frame = 0; frame < 60 * 110 && lap == null; frame++) {
      s.frames(1);
      final car = s.car;
      expect(
        onPavement(car.at),
        isTrue,
        reason: 'on the road at (${car.x.toStringAsFixed(1)}, ${car.z.toStringAsFixed(1)})',
      );
      lap = laps.update(car.x, car.z, frame / 60);
      final at = nearLoop(car.x, car.z);
      if (at != null && car.x.abs() > streetEnd) furthest = math.max(furthest, at.d);
      if (frame > 60 * 5) slowest = math.min(slowest, car.speed);
    }
    expect(furthest, greaterThan(loopLength - 20), reason: 'all the way round');
    expect(lap, isNotNull);
    expect(lap!, inExclusiveRange(60, 100), reason: 'a lap in ${lap.toStringAsFixed(1)} s');
    expect(slowest, greaterThan(10), reason: 'bumping round the bends, never stopped');
  });

  test('a car coming at you shoves you out of its way, off to the side', () {
    final s = _Street();
    final c = s.car;
    final pos = s.player.pos..setValues(c.x + 1, _g, c.z);
    s.fleet.views[_blue].pose.speed = 6;
    expect(s.fleet.shove(pos, null), 6);
    final local = (pos.x - c.x) * math.cos(c.rotY) - (pos.z - c.z) * math.sin(c.rotY);
    final along = (pos.x - c.x) * math.sin(c.rotY) + (pos.z - c.z) * math.cos(c.rotY);
    expect(local.abs() >= Car.width / 2 + 0.32 || along.abs() >= Car.length / 2 + 0.32, isTrue);
  });

  test('lap times read m:ss.t', () {
    expect(lapTime(75.26), '1:15.3');
    expect(lapTime(9.94), '0:09.9');
    expect(lapTime(59.96), '1:00.0');
  });
}
