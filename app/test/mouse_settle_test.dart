// Taking the mouse back from a click holds the view still for the flick of the hand (#191 #198, 665aeec).

import 'package:agent_office/interop/mouse_settle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a lock taken back from a click holds the view until the mouse rests, 150 ms at most', () {
    final s = MouseSettle()..asked(true);
    s.landed(1000);
    expect(s.looks(1020), isFalse, reason: 'the hand that clicked is still moving');
    expect(s.looks(1040), isFalse);
    expect(s.looks(1160), isTrue, reason: 'past 150 ms it looks whatever the mouse does');
    expect(s.looks(1170), isTrue);
  });

  test('a rest of 100 ms ends the hold sooner', () {
    final s = MouseSettle()..asked(true);
    s.landed(0);
    expect(s.looks(10), isFalse);
    expect(s.looks(111), isTrue, reason: 'rested 101 ms');
  });

  test('a lock from a key, or from clicking the office, turns the view at once', () {
    final s = MouseSettle()..asked(false);
    s.landed(0);
    expect(s.looks(5), isTrue);
  });
}
