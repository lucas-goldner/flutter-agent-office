import 'dart:math' as math;

import 'package:agent_office/audio/feet.dart';
import 'package:agent_office/audio/sound_model.dart' show Pos;
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart' show Balcony, Floor, Road, Wing, wingRowZ;

double rms(List<double> xs) => math.sqrt(xs.fold(0.0, (a, x) => a + x * x) / xs.length);

void main() {
  group('what is underfoot', () {
    test('the office, its balcony and the back office are planks; the landing outside is concrete', () {
      expect(groundAt(const Pos(0, 0, 0)), Ground.wood);
      expect(groundAt(const Pos((Balcony.minX + Balcony.maxX) / 2, 0, (Balcony.minZ + Balcony.maxZ) / 2)), Ground.wood);
      expect(groundAt(Pos(Floor.maxX + 1, 0, 0)), Ground.concrete);
      final back = Pos((Wing.minX + Wing.maxX) / 2, 0, wingRowZ(1));
      expect(groundAt(back), Ground.concrete, reason: 'not built out');
      expect(groundAt(back, wing: 1), Ground.wood);
    });

    test('down below: the garage, the lots and the street are concrete, and past them grass', () {
      expect(groundAt(const Pos(0, -3, 0)), Ground.concrete, reason: 'the garage');
      expect(groundAt(const Pos(0, -3, (Road.minZ + Road.maxZ) / 2)), Ground.concrete, reason: 'the street');
      expect(groundAt(const Pos(-80, -3, -40)), Ground.grass);
    });

    test('the roof deck is planks and a hall of its own flagstones, wherever you are', () {
      expect(groundAt(const Pos(-80, -3, -40), roof: true), Ground.wood);
      expect(groundAt(const Pos(0, 0, 0), hall: true), Ground.stone);
    });
  });

  test('a foot: the heel, then the ball of the foot, sooner and harder at a run', () {
    final rng = math.Random(4);
    final walk = [for (var i = 0; i < 50; i++) fall(Ground.wood, 0, 1, 1, rng)];
    final run = [for (var i = 0; i < 50; i++) fall(Ground.wood, 1, 1, 1, rng)];
    double mean(Iterable<double> xs) => xs.reduce((a, b) => a + b) / xs.length;
    expect(walk.every((f) => f.toeAfter >= 0.045 && f.toeAfter <= 0.06), isTrue);
    expect(mean(run.map((f) => f.toeAfter)), lessThan(mean(walk.map((f) => f.toeAfter)) * 0.5));
    expect(mean(run.map((f) => f.heelLevel)), greaterThan(mean(walk.map((f) => f.heelLevel))));
    expect(mean(run.map((f) => f.heelRate)), greaterThan(mean(walk.map((f) => f.heelRate))));
    expect(walk.every((f) => f.toeLevel < f.heelLevel), isTrue);
  });

  test('walking into a wall is silent, and a landing is only a landing from a fall', () {
    expect(stepHeard(2.3, 0.5), isTrue, reason: 'a walk covers 4.6 m/s');
    expect(stepHeard(0.1, 0.5), isFalse, reason: 'pressed up against a wall');
    expect(landing(-3), isNull, reason: 'down a stair');
    expect(landing(-6), closeTo(2 / 7, 1e-9), reason: 'a hop');
    expect(landing(-20), 1);
  });

  test('never the same sample twice running', () {
    final rng = math.Random(1);
    final xs = ['a', 'b', 'c'];
    String? last;
    for (var i = 0; i < 100; i++) {
      final x = another(xs, last, rng);
      expect(x, isNot(last));
      last = x;
    }
    expect(another(['only'], 'only', rng), 'only');
  });

  test('six of each part on every ground, each a sound and no click at its end', () {
    for (final g in Ground.values) {
      final f = footfalls(22050, g, math.Random(g.index + 1));
      expect(f.heel, hasLength(footVariants));
      expect(f.toe, hasLength(footVariants));
      for (final s in [...f.heel, ...f.toe]) {
        expect(s.reduce(math.max), lessThanOrEqualTo(0.9 + 1e-6), reason: '$g: peak');
        expect(rms(s), greaterThan(0.01), reason: '$g: something to hear');
        expect(s.last.abs(), lessThan(0.01), reason: '$g: faded out');
      }
      expect(f.heel[0], isNot(equals(f.heel[1])), reason: 'no two alike');
    }
  });
}
