// The shared part of tests/garage.test.ts (the Garage itself is the server's).
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

const Pedals gas = (gas: 1, turn: 0, brake: false);
const Pedals coast = (gas: 0, turn: 0, brake: false);

/// `seconds` of these pedals, a 60th of a second at a time.
CarPose run(CarPose p, Pedals pedals, double seconds) {
  for (var t = 0.0; t < seconds; t += 1 / 60) {
    p = drive(p, pedals, 1 / 60);
  }
  return p;
}

CarPose still([double x = 0, double z = 0, double rotY = 0]) => CarPose(x: x, z: z, rotY: rotY);
CarPose moving(double speed) => CarPose(x: 0, z: 0, rotY: 0, speed: speed);
({double x, double z, double rotY}) pose(double x, double z, double rotY) => (x: x, z: z, rotY: rotY);
({double x, double z, double rotY}) defPose(CarDef c) => (x: c.x, z: c.z, rotY: c.rotY);
GroundBox box(double minX, double maxX, double minZ, double maxZ) =>
    GroundBox(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ);

void main() {
  test('every car is parked on the pavement, clear of the others and of the elevator', () {
    final lift = box(Elevator.x - Elevator.width / 2, Elevator.x + Elevator.width / 2, Floor.minZ, elevatorFront);
    final boxes = [
      for (final c in cars)
        () {
          final a = carPoint(defPose(c), -Car.width / 2, -Car.length / 2);
          final b = carPoint(defPose(c), Car.width / 2, Car.length / 2);
          return box(math.min(a.x, b.x), math.max(a.x, b.x), math.min(a.z, b.z), math.max(a.z, b.z));
        }(),
    ];
    for (var i = 0; i < cars.length; i++) {
      final c = cars[i];
      expect(onPavement(defPose(c)), isTrue, reason: '${c.name} is on the pavement');
      expect(carOverlaps(defPose(c), lift), isFalse, reason: '${c.name} is out of the elevator');
      for (var j = 0; j < boxes.length; j++) {
        expect(i == j || !carOverlaps(defPose(c), boxes[j]), isTrue, reason: '${c.name} is clear of ${cars[j].name}');
      }
    }
    expect({for (final c in cars) c.name}.length, cars.length, reason: 'no two cars go by the same name');
    expect(parked().length, cars.length);
  });

  test('a car on the gas gets up to top speed and no faster, and rolls to a dead stop off it', () {
    var p = run(still(), gas, 2);
    expect(p.speed > 12 && p.speed < Drive.top, isTrue, reason: 'quick off the line (${p.speed} m/s after 2 s)');
    p = run(p, gas, 10);
    expect(p.speed, Drive.top);
    expect(p.x.abs() < 1e-9 && p.z > 100, isTrue, reason: 'straight ahead, along its nose');
    p = run(p, coast, 20);
    expect(p.speed, 0, reason: 'stopped, not creeping');
    expect(run(p, coast, 1).z, p.z);
  });

  test('the brake stops it quickly, and S brakes before it reverses', () {
    final fast = moving(Drive.top);
    expect(run(fast, (gas: 1, turn: 0, brake: true), 1.1).speed, 0, reason: 'the brake beats the gas');
    const Pedals back = (gas: -1, turn: 0, brake: false);
    final braking = run(fast, back, 0.5);
    expect(braking.speed > 0 && braking.speed < fast.speed, isTrue, reason: 'still going forward, slower');
    expect(run(fast, back, 6).speed, -Drive.reverse, reason: 'then backs up, only so fast');
  });

  test('A turns left and D right, going forward; backing up swings the other way', () {
    final left = run(moving(5), (gas: 0.4, turn: 1, brake: false), 0.5);
    expect(left.rotY > 0.1 && left.x > 0, isTrue, reason: 'left of +z is +x');
    final right = run(moving(5), (gas: 0.4, turn: -1, brake: false), 0.5);
    expect(right.rotY < -0.1 && right.x < 0, isTrue);
    final back = run(moving(-4), (gas: -1, turn: 1, brake: false), 0.5);
    expect(back.rotY, lessThan(-0.1), reason: 'reversing with the wheel left, the nose swings right');
  });

  test('it turns tighter slowly than flat out, so it never spins at speed', () {
    double radius(double speed) => Drive.wheelbase / math.tan(steerLimit(speed));
    expect(radius(3), lessThan(7));
    expect(radius(Drive.top), greaterThan(2 * radius(3)));
    // The wheel takes a moment to turn all the way, and then holds there.
    final p = run(moving(10), (gas: 0, turn: 1, brake: false), 0.05);
    expect(p.steer > 0 && p.steer < steerLimit(10), isTrue);
    expect((run(p, (gas: 1, turn: 1, brake: false), 1).steer - steerLimit(Drive.top)).abs(), lessThan(0.05));
  });

  test('you can drive out of the garage, across the lot and down the street, but not onto the grass', () {
    // A Ferrari backed in facing the street drives straight out onto the road.
    final ferrari = cars.firstWhere((c) => c.kind == CarKind.ferrari);
    for (var z = ferrari.z; z <= (Road.minZ + Road.maxZ) / 2; z += 0.5) {
      expect(onPavement(pose(ferrari.x, z, ferrari.rotY)), isTrue, reason: 'z $z');
    }
    // Turned along the road, both ways, and on past either end of the street onto the scenic loop.
    const road = (Road.minZ + Road.maxZ) / 2;
    for (final x in [80.0, 105.0, 115.0, 130.0]) {
      expect(onPavement(pose(x, road, math.pi / 2)), isTrue, reason: 'east, x $x');
      expect(onPavement(pose(-x, road, -math.pi / 2)), isTrue, reason: 'west, x ${-x}');
    }
    expect(onPavement(pose(125, road + 8, math.pi / 2)), isFalse, reason: 'not off the side of the loop');
    expect(onPavement(pose(-40, 18, 0)), isFalse, reason: 'the lawn beside the lot');
    expect(onPavement(pose(0, Floor.minZ - 1, math.pi / 2)), isFalse, reason: 'through the back wall');
    expect(paved(0, Road.maxZ + 1.5), isFalse, reason: 'the far sidewalk');
    expect(pavement.every((b) => b.minX < b.maxX && b.minZ < b.maxZ), isTrue);
  });

  test("a car's turned footprint only overlaps what it really touches", () {
    final diag = pose(0, 0, math.pi / 4);
    // Inside the square round it, but past its corner: clear.
    final corner = carPoint(diag, Car.width / 2, Car.length / 2);
    expect(carOverlaps(diag, box(corner.x + 0.3, corner.x + 0.8, corner.z - 0.2, corner.z + 0.2)), isFalse);
    final r = math.sqrt(Car.width * Car.width + Car.length * Car.length) / 2;
    expect(carOverlaps(diag, box(r - 0.4, r, r - 0.4, r)), isFalse, reason: 'the empty corner of its bounding square');
    // Right by its side: hit.
    final side = carPoint(diag, Car.width / 2 + 0.05, 0);
    expect(carOverlaps(diag, box(side.x - 0.2, side.x + 0.2, side.z - 0.2, side.z + 0.2)), isTrue);
    final x0 = cars[0].x;
    expect(carFits(pose(x0, 0, 0), [box(x0 - 0.25, x0 + 0.25, -0.25, 0.25)]), isFalse, reason: 'a column in the way');
    expect(carFits(pose(x0, 0, 0), const []), isTrue, reason: 'the aisle, with nothing there');
  });

  test('a car reads and writes the wire as the office sends it', () {
    final j = {'x': 1.5, 'z': -2.0, 'rotY': 0.5, 'speed': 3.0, 'steer': 0.1, 'driver': 'p1'};
    expect(CarState.fromJson(j).toJson(), j);
  });
}
