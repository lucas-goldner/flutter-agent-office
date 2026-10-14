import 'package:agent_office_server/src/garage.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

/// The server's side of upstream's tests/garage.test.ts: who's in which car, and who drives it.
void main() {
  Map<String, dynamic> j(CarState c) => c.toJson();
  List<double> pose(CarPose p) => [p.x, p.z, p.rotY, p.speed, p.steer];

  test('the garage: one driver and one passenger a car, and only the driver moves it', () {
    final g = Garage();
    expect(g.state().map(j), parked().map(j), reason: 'everything in its spot to start with');
    expect(g.enter('ann', 1, CarSeat.driver), isTrue);
    expect(g.enter('bob', 1, CarSeat.driver), isFalse, reason: "Ann's driving");
    expect(g.enter('bob', 1, CarSeat.passenger), isTrue);
    expect(g.enter('cat', 1, CarSeat.passenger), isFalse, reason: 'full');
    expect(g.seatOf('bob'), (car: 1, seat: CarSeat.passenger));
    const p = CarPose(x: 0, z: 18, rotY: 1, speed: 12, steer: 0.1);
    expect(g.drive('bob', 1, p), isNull, reason: "the passenger doesn't steer");
    expect(pose(g.drive('ann', 1, p)!), pose(p));
    expect(pose(g.state()[1]), pose(p));
    expect(g.drive('ann', 1, const CarPose(x: -60, z: 18, rotY: 1, speed: 12, steer: 0.1)), isNull, reason: 'grass');
    expect(g.drive('ann', 1, const CarPose(x: 0, z: 18, rotY: 1, speed: double.nan)), isNull, reason: 'nonsense');
    expect(g.drive('ann', 1, const CarPose(x: 0, z: 18, rotY: 1, speed: 999))?.speed, Drive.top);
    expect(g.enter('ann', 1, null), isFalse);
    // Ann gets out: it stops where she left it, with Bob still in it.
    expect(g.leave('ann'), isTrue);
    expect(g.leave('ann'), isFalse, reason: 'already out');
    final left = g.state()[1];
    expect(left.driver, isNull);
    expect(left.passenger, 'bob');
    expect([left.x, left.z, left.speed, left.steer], [0, 18, 0, 0]);
    // Bob slides over behind the wheel (out of the passenger seat into it), then leaves for good.
    expect(g.enter('bob', 1, CarSeat.driver), isTrue);
    expect(g.state()[1].passenger, isNull);
    expect(g.leave('bob'), isTrue);
    expect(g.enter('ann', 99, CarSeat.driver), isFalse, reason: 'no such car');
    expect(g.enter('ann', -1, CarSeat.driver), isFalse, reason: 'no such car');
    // A heading the long way round comes back between -pi and pi.
    g.enter('ann', 0, CarSeat.driver);
    expect(g.drive('ann', 0, const CarPose(x: 0, z: 18, rotY: 7))!.rotY, closeTo(7 - 2 * 3.141592653589793, 1e-9));
  });

  test('the garage: a horn only from inside a car, and not faster than a person can press it', () {
    var now = 1000000;
    final g = Garage(now: () => now);
    expect(g.honk('ann'), isNull, reason: 'not in a car');
    g.enter('ann', 3, CarSeat.passenger);
    expect(g.honk('ann'), 3);
    expect(g.honk('ann'), isNull, reason: 'leaning on it');
    now += 300;
    expect(g.honk('ann'), 3);
  });
}
