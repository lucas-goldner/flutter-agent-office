// The cars in the garage, as the office last said (state/slices/cars.ts): where each one is, who's in
// it, and when (nowMs) each one's driver last said where it is. Their moves change them without a word,
// like people's; [changed] is for who's in which.

import 'package:flutter/foundation.dart';
import 'package:office_shared/garage.dart';
import 'package:office_shared/protocol.dart';

import 'store.dart' show nowMs;

class CarsState {
  List<CarSlot> cars = [for (final c in parked()) CarSlot.of(c)];
  List<double> at = [];

  /// Who's in which car changed (a `cars` message, or a floor arrived): [answer] when it answered
  /// a car.enter or car.leave of yours.
  final ValueNotifier<({int n, bool answer})> changed = ValueNotifier((n: 0, answer: false));

  void _set(List<CarState> list, {bool answer = false}) {
    cars = [for (final c in list) CarSlot.of(c)];
    final now = nowMs();
    at = [for (final _ in cars) now];
    changed.value = (n: changed.value.n + 1, answer: answer);
  }

  /// The car [id] (a PeerInfo id) is in on this floor, and which seat.
  ({int car, CarSeat seat})? carOf(String id) {
    for (var i = 0; i < cars.length; i++) {
      if (cars[i].driver == id) return (car: i, seat: CarSeat.driver);
      if (cars[i].passenger == id) return (car: i, seat: CarSeat.passenger);
    }
    return null;
  }

  void apply(ServerMsg msg) {
    switch (msg) {
      case WelcomeMsg m:
        _set(m.view.cars.isEmpty ? parked() : m.view.cars);
      case FloorEnterMsg m:
        _set(m.view.cars.isEmpty ? parked() : m.view.cars);
      case CarsMsg m:
        _set(m.cars, answer: m.answer ?? false);
      case CarMoveMsg m:
        if (m.car < 0 || m.car >= cars.length) return;
        cars[m.car]
          ..x = m.x
          ..z = m.z
          ..rotY = m.rotY
          ..speed = m.speed
          ..steer = m.steer;
        while (at.length <= m.car) {
          at.add(nowMs());
        }
        at[m.car] = nowMs();
      default:
        break;
    }
  }
}

/// A car as the office has it: where its driver last said it was, and who's in it.
class CarSlot {
  CarSlot(this.x, this.z, this.rotY, [this.speed = 0, this.steer = 0, this.driver, this.passenger]);
  factory CarSlot.of(CarState c) => CarSlot(c.x, c.z, c.rotY, c.speed, c.steer, c.driver, c.passenger);
  double x, z, rotY, speed, steer;
  String? driver, passenger;

  String? who(CarSeat seat) => seat == CarSeat.driver ? driver : passenger;
}
