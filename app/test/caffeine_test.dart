import 'package:agent_office/caffeine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a cup gives a minute of buzz that fades out at the end', () {
    final c = Caffeine();
    expect(c.buzzed(0), isFalse);
    expect(c.speed(0), 1);
    expect(c.drink(10), isFalse);
    expect(c.cups, 1);
    expect(c.buzzed(10), isTrue);
    expect(c.left(10), buzzSeconds);
    expect(c.speed(20), closeTo(1.4, 1e-9));
    expect(c.jump(20), closeTo(1.2, 1e-9));
    // Two seconds left: half strength.
    expect(c.speed(68), closeTo(1.2, 1e-9));
    expect(c.buzzed(70), isFalse);
    expect(c.left(80), 0);
    expect(c.speed(80), 1);
  });

  test('the third cup in a row brings on the jitters, which settle over the last second', () {
    final c = Caffeine();
    c.drink(0);
    expect(c.drink(5), isFalse);
    expect(c.cups, 2);
    expect(c.drink(6), isTrue);
    expect(c.cups, 3);
    expect(c.jitter(6), 1);
    expect(c.jitter(9.5), closeTo(0.5, 1e-9));
    expect(c.jitter(10), 0);
    expect(c.left(6), buzzSeconds);
  });

  test('a cup after the buzz wore off starts the count again', () {
    final c = Caffeine();
    c.drink(0);
    c.drink(30);
    expect(c.cups, 2);
    c.drink(200);
    expect(c.cups, 1);
    expect(c.jitter(200), 0);
  });
}
