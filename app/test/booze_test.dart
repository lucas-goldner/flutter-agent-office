import 'package:agent_office/booze.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/rooftop.dart';

void main() {
  Drink d(DrinkId id) => id.drink;

  test('a drink kicks in over a few seconds, then wears off over a minute or so', () {
    final b = Booze();
    expect(b.amount(0), 0);
    b.drink(d(DrinkId.beer), 0);
    expect(b.amount(0), 0);
    final soon = b.amount(1);
    expect(soon, greaterThan(0));
    final peak = b.amount(6);
    expect(peak, greaterThan(soon));
    expect(peak, lessThan(0.28));
    expect(b.amount(20), lessThan(peak));
    expect(b.amount(60), 0);
  });

  test('the same drinks at the same times feel about the same, however often you ask', () {
    double run(List<double> checks) {
      final b = Booze()
        ..drink(d(DrinkId.shot), 0)
        ..drink(d(DrinkId.martini), 2);
      for (final t in checks) {
        b.amount(t);
      }
      return b.amount(30);
    }

    expect(run([]), closeTo(run([1, 3, 5, 8, 13, 21]), 0.02));
    expect(run([1, 3, 5, 8, 13, 21]), run([1, 3, 5, 8, 13, 21]));
  });

  test('they add up, and you get tipsy, drunk and then wasted', () {
    final b = Booze();
    expect(b.stage(0), 0);
    b.drink(d(DrinkId.beer), 0);
    expect(b.stage(4), 1);
    b.drink(d(DrinkId.shot), 4);
    expect(b.stage(12), 2);
    b
      ..drink(d(DrinkId.martini), 12)
      ..drink(d(DrinkId.maitai), 13);
    expect(b.stage(20), 3);
    expect(feelings, hasLength(4));
  });

  test("past the limit the bartender cuts you off, counting what hasn't kicked in yet", () {
    final b = Booze();
    var t = 0.0;
    while (!b.cutOff(t)) {
      b.drink(d(DrinkId.shot), t);
      t += 0.5;
    }
    expect(t, lessThan(3));
    expect(b.amount(t), lessThan(boozeLimit));
    // …and after a while you're good for another.
    expect(b.cutOff(t + 200), isFalse);
  });

  test('water sobers you up a little, and a mocktail does nothing', () {
    final b = Booze()..drink(d(DrinkId.wine), 0);
    final before = b.amount(10);
    b.drink(d(DrinkId.water), 10);
    expect(b.amount(10), closeTo((before - 0.3).clamp(0, 9), 1e-9));
    final c = Booze()..drink(d(DrinkId.mojito), 0);
    expect(c.amount(10), 0);
  });

  test('you hold the glass for a while, and put it down leaving the roof', () {
    final b = Booze()..drink(d(DrinkId.beer), 0);
    expect(b.holding(10)?.id, DrinkId.beer);
    expect(b.holding(glassSeconds + 1), isNull);
    b.drink(d(DrinkId.wine), 50);
    b.putDown();
    expect(b.holding(51), isNull);
  });

  test('the menu says how hard each drink hits, and the bartender has a word for each', () {
    expect(drinkKick(d(DrinkId.water)), contains('sobers'));
    expect(drinkKick(d(DrinkId.mojito)), 'no alcohol');
    expect(drinkKick(d(DrinkId.beer)), '🌀 light');
    expect(drinkKick(d(DrinkId.martini)), '🌀🌀 goes to your head');
    expect(drinkKick(d(DrinkId.shot)), '🌀🌀🌀 strong');
    for (final x in drinks) {
      expect(cheers[x.id], isNotNull);
    }
  });
}
