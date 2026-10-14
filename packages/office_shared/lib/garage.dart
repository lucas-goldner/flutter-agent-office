// The Lambos and Ferraris in the garage, which anyone can drive: where they're parked, where you can
// take them (the garage, the lots round it, the street and the scenic loop off either end of it), and
// the arcade physics a driver's own page runs. Everyone else on the floor sees the car where its
// driver says it is.
// Ported from src/shared/garage.ts.

import 'dart:math' as math;

import 'json_util.dart';
import 'layout.dart';
import 'scenic.dart';

enum CarKind implements WireEnum {
  lambo('lambo'),
  ferrari('ferrari');

  const CarKind(this.wire);
  @override
  final String wire;
}

/// A car's footprint (nose to tail along its length), and how high its body and its roof come up.
abstract final class Car {
  static const double length = 4.6;
  static const double width = 2;
  static const double body = 0.82;
  static const double roof = 1.12;
}

/// Somewhere flat on the ground, x and z.
class GroundBox {
  const GroundBox({required this.minX, required this.maxX, required this.minZ, required this.maxZ});

  final double minX;
  final double maxX;
  final double minZ;
  final double maxZ;
}

/// The building's footprint, walls included: the garage is under it.
abstract final class _B {
  static const double maxX = Floor.maxX + wallT;
  static const double minZ = Floor.minZ - wallT;
  static const double maxZ = Floor.maxZ + wallT;
}

/// The paved lot in front of the garage, out to the sidewalk, and the one down its east side.
const GroundBox lot = GroundBox(minX: -30, maxX: 30, minZ: _B.maxZ, maxZ: 21);
const GroundBox sideLot = GroundBox(minX: _B.maxX, maxX: _B.maxX + 12, minZ: _B.minZ - 2, maxZ: _B.maxZ + 4);

/// Where a car can go, besides the scenic loop (see scenic.dart), which takes over from either end of
/// the street: the garage (inside its back and west walls, open to the south and east), the lots
/// round it, across the sidewalk and along the street. What stands on them (columns, lamps, trees,
/// the other cars) is the driver's page to bump into.
const List<GroundBox> pavement = [
  GroundBox(minX: Floor.minX, maxX: _B.maxX, minZ: Floor.minZ, maxZ: _B.maxZ),
  GroundBox(minX: -30, maxX: 30, minZ: _B.maxZ, maxZ: Road.minZ),
  sideLot,
  GroundBox(minX: -streetEnd, maxX: streetEnd, minZ: Road.minZ, maxZ: Road.maxZ),
];

class CarDef {
  const CarDef({
    required this.kind,
    required this.color,
    required this.name,
    required this.x,
    required this.z,
    required this.rotY,
  });

  final CarKind kind;
  final String color;

  /// What the hint calls it: "Orange Lambo".
  final String name;

  /// Its spot: where it's parked when the office starts, and which way its nose points (0 is +z).
  final double x;
  final double z;
  final double rotY;
}

// Lambos nose-in along the back wall, Ferraris backed in facing the street, and one out front.
const double _back = _B.minZ + wallT + 0.4 + Car.length / 2;
const double _front = _B.maxZ - 0.5 - Car.length / 2;
const List<CarDef> cars = [
  CarDef(kind: CarKind.lambo, color: '#8ac926', name: 'Lime Lambo', x: -14.4, z: _back, rotY: math.pi),
  CarDef(kind: CarKind.lambo, color: '#ff7b00', name: 'Orange Lambo', x: -8, z: _back, rotY: math.pi),
  CarDef(kind: CarKind.lambo, color: '#ffd000', name: 'Yellow Lambo', x: 1.6, z: _back, rotY: math.pi),
  CarDef(kind: CarKind.lambo, color: '#7b2cbf', name: 'Purple Lambo', x: 11.2, z: _back, rotY: math.pi),
  CarDef(kind: CarKind.ferrari, color: '#d90429', name: 'Red Ferrari', x: -14.4, z: _front, rotY: 0),
  CarDef(kind: CarKind.ferrari, color: '#d90429', name: 'Rosso Ferrari', x: -4.8, z: _front, rotY: 0),
  CarDef(kind: CarKind.ferrari, color: '#ffc300', name: 'Giallo Ferrari', x: 4.8, z: _front, rotY: 0),
  CarDef(kind: CarKind.ferrari, color: '#e5383b', name: 'Scarlet Ferrari', x: 14.4, z: _front, rotY: 0),
  // Left out front, for everyone upstairs to look at.
  CarDef(kind: CarKind.lambo, color: '#00b4d8', name: 'Blue Lambo', x: 9, z: 18.2, rotY: math.pi / 2),
];

enum CarSeat implements WireEnum {
  driver('driver'),
  passenger('passenger');

  const CarSeat(this.wire);
  @override
  final String wire;

  static CarSeat? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// Where the two of you sit, in the car's own frame (x across, +x on the driver's left side; z toward
/// the nose), and how high your hips are off the ground. Your head's up out of the top: with anyone
/// in it, the roof comes off.
const Map<CarSeat, ({double x, double z})> carSeats = {
  CarSeat.driver: (x: 0.42, z: -0.5),
  CarSeat.passenger: (x: -0.42, z: -0.5),
};
const double seatHips = 0.45;

/// A car where it is and how it's going: [speed] in m/s along its nose (negative in reverse), [steer]
/// the front wheels' angle (+ is left).
class CarPose {
  const CarPose({required this.x, required this.z, required this.rotY, this.speed = 0, this.steer = 0});

  final double x;
  final double z;
  final double rotY;
  final double speed;
  final double steer;
}

/// A car as the office has it: where it is, and who's in it (PeerInfo ids).
class CarState extends CarPose {
  const CarState({
    required super.x,
    required super.z,
    required super.rotY,
    super.speed,
    super.steer,
    this.driver,
    this.passenger,
  });

  factory CarState.fromJson(Map<String, dynamic> j) => CarState(
    x: asDouble(j['x']),
    z: asDouble(j['z']),
    rotY: asDouble(j['rotY']),
    speed: asDouble(j['speed']),
    steer: asDouble(j['steer']),
    driver: asStringOrNull(j['driver']),
    passenger: asStringOrNull(j['passenger']),
  );

  final String? driver;
  final String? passenger;

  Map<String, dynamic> toJson() => {
    'x': x,
    'z': z,
    'rotY': rotY,
    'speed': speed,
    'steer': steer,
    'driver': ?driver,
    'passenger': ?passenger,
  };
}

/// Every car in its spot, as the office starts.
List<CarState> parked() => [for (final c in cars) CarState(x: c.x, z: c.z, rotY: c.rotY)];

/// The pedals and the wheel: [gas] 1 forward, -1 back (braking first if you're going the other way),
/// [turn] +1 hard left.
typedef Pedals = ({double gas, double turn, bool brake});

abstract final class Drive {
  /// Flat out, forward and in reverse (m/s).
  static const double top = 20;
  static const double reverse = 7;

  /// Speeding up, forward and back, and slowing down on the brake or rolling (m/s²).
  static const double accel = 8;
  static const double reverseAccel = 5;
  static const double brake = 20;
  static const double coast = 2.5;

  /// Between the axles (m): how tight it turns.
  static const double wheelbase = 2.8;

  /// How far the front wheels turn at a crawl (radians): less the faster you go, so it doesn't spin out.
  static const double steer = 0.6;

  /// How fast they turn (radians a second).
  static const double steerRate = 2.8;
}

double _clamp(double v, double lo, double hi) => math.min(hi, math.max(lo, v));

/// How far the front wheels can turn at [speed].
double steerLimit(double speed) => Drive.steer / (1 + speed.abs() / 9);

/// The car [dt] seconds on, with these pedals: a bicycle model, no sliding.
CarPose drive(CarPose p, Pedals pedals, double dt) {
  final want = _clamp(pedals.turn, -1, 1) * steerLimit(p.speed);
  final steer = p.steer + _clamp(want - p.steer, -Drive.steerRate * dt, Drive.steerRate * dt);
  var v = p.speed;
  void toward(double target, double rate) => v += _clamp(target - v, -rate * dt, rate * dt);
  final gas = _clamp(pedals.gas, -1, 1);
  if (pedals.brake) {
    toward(0, Drive.brake);
  } else if (gas > 0) {
    if (v < 0) {
      toward(0, Drive.brake);
    } else {
      v = math.min(Drive.top, v + Drive.accel * gas * dt);
    }
  } else if (gas < 0) {
    if (v > 0) {
      toward(0, Drive.brake);
    } else {
      v = math.max(-Drive.reverse, v + Drive.reverseAccel * gas * dt);
    }
  } else {
    toward(0, Drive.coast);
  }
  final yaw = (v * math.tan(steer)) / Drive.wheelbase;
  final mid = p.rotY + (yaw * dt) / 2;
  return CarPose(
    x: p.x + math.sin(mid) * v * dt,
    z: p.z + math.cos(mid) * v * dt,
    rotY: math.atan2(math.sin(p.rotY + yaw * dt), math.cos(p.rotY + yaw * dt)),
    speed: v,
    steer: steer,
  );
}

/// A point in the car's own frame (x across, +x left; z toward the nose), out in the world.
({double x, double z}) carPoint(({double x, double z, double rotY}) p, double lx, double lz) {
  final s = math.sin(p.rotY);
  final c = math.cos(p.rotY);
  return (x: p.x + lx * c + lz * s, z: p.z - lx * s + lz * c);
}

/// Whether (x, z) is somewhere a car can be: the garage, the lots, the street or the loop.
bool paved(double x, double z) =>
    pavement.any((b) => x >= b.minX && x <= b.maxX && z >= b.minZ && z <= b.maxZ) || onLoop(x, z);

/// Whether the whole car is on the pavement: its corners, and halfway along each side.
bool onPavement(({double x, double z, double rotY}) p) {
  const w = Car.width / 2;
  const l = Car.length / 2;
  for (final (lx, lz) in const [(w, l), (-w, l), (w, -l), (-w, -l), (w, 0.0), (-w, 0.0), (0.0, l), (0.0, -l)]) {
    final at = carPoint(p, lx, lz);
    if (!paved(at.x, at.z)) return false;
  }
  return true;
}

/// Whether the car's footprint (a rectangle turned by rotY) overlaps box [b] (separating axes).
bool carOverlaps(({double x, double z, double rotY}) p, GroundBox b) {
  const hx = Car.width / 2;
  const hz = Car.length / 2;
  final ex = (b.maxX - b.minX) / 2;
  final ez = (b.maxZ - b.minZ) / 2;
  final dx = (b.minX + b.maxX) / 2 - p.x;
  final dz = (b.minZ + b.maxZ) / 2 - p.z;
  final s = math.sin(p.rotY).abs();
  final c = math.cos(p.rotY).abs();
  if (dx.abs() >= c * hx + s * hz + ex) return false;
  if (dz.abs() >= s * hx + c * hz + ez) return false;
  final sn = math.sin(p.rotY);
  final cs = math.cos(p.rotY);
  // Across the car, and along it.
  if ((dx * cs - dz * sn).abs() >= hx + ex * c + ez * s) return false;
  if ((dx * sn + dz * cs).abs() >= hz + ex * s + ez * c) return false;
  return true;
}

/// Whether the car can be at [p]: on the pavement, clear of all of [solids].
bool carFits(({double x, double z, double rotY}) p, Iterable<GroundBox> solids) {
  if (!onPavement(p)) return false;
  for (final b in solids) {
    if (carOverlaps(p, b)) return false;
  }
  return true;
}

/// A pose as the record the helpers above take.
({double x, double z, double rotY}) poseOf(CarPose p) => (x: p.x, z: p.z, rotY: p.rotY);
