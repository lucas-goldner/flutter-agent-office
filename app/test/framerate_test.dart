// When the 3D office offers the 2D view for being slow (framerate.dart): frames averaging 50 ms or more
// through ten seconds, once it has warmed up, and only once. A port of tests/framerate.test.ts.

import 'package:agent_office/framerate.dart';
import 'package:flutter_test/flutter_test.dart';

/// Draws frames [dt] ms apart from [from] for [ms]; whether any of them said slow, and when it ended.
({bool slow, double at}) run(SlowFrames s, double from, double ms, double dt) {
  var slow = false;
  var at = from;
  for (; at < from + ms; at += dt) {
    slow = s.frame(at, dt) || slow;
  }
  return (slow: slow, at: at);
}

void main() {
  test('a computer drawing 10 frames a second is slow, once the office has warmed up', () {
    final s = SlowFrames();
    // The first 8 seconds (loading, shaders compiling) don't count, nor do the 10 after only partly.
    expect(run(s, 0, 17000, 100).slow, isFalse);
    expect(run(s, 17000, 2000, 100).slow, isTrue);
  });

  test('60 or 25 frames a second is fine', () {
    for (final dt in [1000 / 60, 40.0]) {
      expect(run(SlowFrames(), 0, 60000, dt).slow, isFalse);
    }
  });

  test('it says so once', () {
    final s = SlowFrames();
    expect(run(s, 0, 20000, 100).slow, isTrue);
    expect(run(s, 20000, 60000, 100).slow, isFalse);
  });

  test('a hidden tab, or a stall, starts the count over rather than counting as slow', () {
    final s = SlowFrames();
    final at = run(s, 0, 8000, 16).at;
    // Fast frames, a 30 s gap (the tab was hidden), and a few slow ones after: not ten seconds of them.
    var now = run(s, at, 9000, 16).at + 30000;
    expect(s.frame(now, 30000), isFalse);
    now += 100;
    expect(run(s, now, 5000, 100).slow, isFalse);
  });

  test('a few hitches in otherwise smooth frames are fine', () {
    final s = SlowFrames();
    var slow = false;
    var at = 0.0;
    for (var i = 0; at < 60000; i++) {
      final dt = i % 50 == 0 ? 400.0 : 16.0;
      at += dt;
      slow = s.frame(at, dt) || slow;
    }
    expect(slow, isFalse);
  });
}
