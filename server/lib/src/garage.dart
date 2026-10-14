// A floor's cars. Port of src/server/garage.ts.

import 'dart:math' as math;

import 'package:office_shared/shared.dart' show CarPose, CarSeat, CarState, Drive, parked, paved;

/// How often one person can honk, at most (ms).
const honkEvery = 250;

/// One car as the office has it now.
class _Car {
  _Car(CarState c) : x = c.x, z = c.z, rotY = c.rotY, speed = c.speed, steer = c.steer;

  double x, z, rotY, speed, steer;
  String? driver;
  String? passenger;

  String? seat(CarSeat s) => s == CarSeat.driver ? driver : passenger;

  void sit(CarSeat s, String? id) => s == CarSeat.driver ? driver = id : passenger = id;

  CarState get state =>
      CarState(x: x, z: z, rotY: rotY, speed: speed, steer: steer, driver: driver, passenger: passenger);
}

/// A floor's cars: who's in each one, and where its driver last said it is. Each driver's page drives
/// its own car (see shared garage.dart) and the office passes it on. Nothing is saved: when the office
/// restarts, every car is back in its spot.
class Garage {
  Garage({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  final List<_Car> _cars = [for (final c in parked()) _Car(c)];
  final Map<String, int> _honked = {};

  /// Every car as it is now, for the floor's pages.
  List<CarState> state() => [for (final c in _cars) c.state];

  /// The car [id] is in, and which seat.
  ({int car, CarSeat seat})? seatOf(String id) {
    for (var i = 0; i < _cars.length; i++) {
      if (_cars[i].driver == id) return (car: i, seat: CarSeat.driver);
      if (_cars[i].passenger == id) return (car: i, seat: CarSeat.passenger);
    }
    return null;
  }

  /// [id] gets into [seat] of car [car], out of wherever they were: only if it's free. Says whether anything changed.
  bool enter(String id, int car, CarSeat? seat) {
    final c = car >= 0 && car < _cars.length ? _cars[car] : null;
    if (c == null || seat == null || c.seat(seat) != null) return false;
    leave(id);
    c.sit(seat, id);
    return true;
  }

  /// [id] gets out (or left the floor, or the office). A car nobody's driving stops where it is. Says whether they were in one.
  bool leave(String id) {
    _honked.remove(id);
    final at = seatOf(id);
    if (at == null) return false;
    final c = _cars[at.car]..sit(at.seat, null);
    if (at.seat == CarSeat.driver) {
      c
        ..speed = 0
        ..steer = 0;
    }
    return true;
  }

  /// The driver of car [car] says where it's got to: where the office has it now, to pass on. Nothing
  /// from anyone else, or from off the pavement.
  CarPose? drive(String id, int car, CarPose pose) {
    final c = car >= 0 && car < _cars.length ? _cars[car] : null;
    if (c == null || c.driver != id) return null;
    final CarPose(:x, :z, :rotY, :speed, :steer) = pose;
    if (![x, z, rotY, speed, steer].every((v) => v.isFinite) || !paved(x, z)) return null;
    c
      ..x = x
      ..z = z
      ..rotY = math.atan2(math.sin(rotY), math.cos(rotY))
      ..speed = math.min(Drive.top, math.max(-Drive.reverse, speed))
      ..steer = math.min(Drive.steer, math.max(-Drive.steer, steer));
    return CarPose(x: c.x, z: c.z, rotY: c.rotY, speed: c.speed, steer: c.steer);
  }

  /// [id] leans on the horn: the car they're in, unless they only just did.
  int? honk(String id) {
    final at = seatOf(id);
    if (at == null) return null;
    final now = _now();
    final last = _honked[id];
    if (last != null && now - last < honkEvery) return null;
    _honked[id] = now;
    return at.car;
  }
}
