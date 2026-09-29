import 'package:agent_office_server/src/court.dart';
import 'package:test/test.dart';

void main() {
  const throwAt = (x: -12.0, y: 1.4, z: 10.0, vx: -5.0, vy: 6.0, vz: 0.0);

  test('the court: one person has the ball at a time, and only they can throw it', () {
    var now = 1000000;
    final c = Court(() => now);
    expect(c.state().toJson(), <String, dynamic>{}, reason: 'under the hoop to start with');
    expect(c.take('ann'), isTrue);
    expect(c.take('bob'), isFalse, reason: 'Ann has it');
    expect(c.state().toJson(), {'holder': 'ann'});
    expect(c.throwBall('bob', throwAt), isFalse, reason: "it isn't Bob's to throw");
    expect(c.throwBall('ann', throwAt), isTrue);
    now += 400;
    expect(c.state().toJson(), {
      'shot': {'x': -12.0, 'y': 1.4, 'z': 10.0, 'vx': -5.0, 'vy': 6.0, 'vz': 0.0, 'by': 'ann', 'elapsed': 400},
    });
    expect(c.take('bob'), isTrue, reason: 'Bob catches the rebound');
    expect(
      c.throwBall('bob', (x: -12.0, y: 1.4, z: 10.0, vx: 1e6, vy: 6.0, vz: 0.0)),
      isFalse,
      reason: 'not that fast',
    );
  });

  test('the court: leaving the floor with the ball puts it back under the hoop', () {
    final c = Court();
    expect(c.take('ann'), isTrue);
    expect(c.left('bob'), isFalse, reason: "Bob didn't have it");
    expect(c.left('ann'), isTrue);
    expect(c.state().toJson(), <String, dynamic>{});
  });

  test('the court: nobody grabs the ball over and over faster than a person could', () {
    var now = 1000000;
    final c = Court(() => now);
    const drop = (x: -12.0, y: 1.4, z: 10.0, vx: 0.0, vy: 0.0, vz: 0.0);
    expect(c.take('ann'), isTrue);
    expect(c.throwBall('ann', drop), isTrue);
    expect(c.take('ann'), isFalse, reason: 'straight back again is too soon');
    now += 200;
    expect(c.take('ann'), isTrue);
  });
}
