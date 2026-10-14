// The cars as the office last said (state/slices/cars.ts): who's in which, where they've been driven,
// and a floor's cars as you arrive on it.

import 'package:agent_office/state/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/garage.dart';
import 'package:office_shared/protocol.dart';

void main() {
  test('who is in which car, and where a driver says it has got to', () {
    final s = Store();
    expect(s.cars.cars, hasLength(cars.length), reason: 'parked, before anyone says');
    final answers = <bool>[];
    s.cars.changed.addListener(() => answers.add(s.cars.changed.value.answer));
    final list = parked().toList();
    list[2] = CarState(x: list[2].x, z: list[2].z, rotY: list[2].rotY, driver: 'me', passenger: 'pal');
    s.apply(CarsMsg(list, answer: true));
    expect(answers, [true]);
    expect(s.cars.carOf('me'), (car: 2, seat: CarSeat.driver));
    expect(s.cars.carOf('pal'), (car: 2, seat: CarSeat.passenger));
    expect(s.cars.carOf('nobody'), isNull);
    s.apply(const CarMoveMsg(car: 2, x: 5, z: 18, rotY: 1, speed: 7, steer: 0.1));
    expect(s.cars.cars[2].x, 5);
    expect(s.cars.cars[2].speed, 7);
    expect(s.cars.at[2], greaterThan(0));
    expect(answers, hasLength(1), reason: 'a move is not news of who is in it');
    s.apply(const CarMoveMsg(car: 99, x: 0, z: 0, rotY: 0, speed: 0, steer: 0));
  });
}
