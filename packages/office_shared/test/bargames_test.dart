// Port of tests/bargames.test.ts.
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

/// A point `r` meters out from the board's middle, `deg` degrees clockwise from straight up.
(double, double) at(double r, double deg) => (r * math.sin((deg * math.pi) / 180), r * math.cos((deg * math.pi) / 180));
BarScore dart((double, double) p) => dartScore(p.$1, p.$2);

void main() {
  test('darts: the numbers go round the board clockwise from 20 at the top', () {
    const single = (DartRings.outer + DartRings.trebleIn) / 2;
    expect(dart(at(single, 0)), (points: 20, label: '20'));
    expect(dart(at(single, 18)), (points: 1, label: '1'));
    expect(dart(at(single, 90)), (points: 6, label: '6'));
    expect(dart(at(single, 180)), (points: 3, label: '3'));
    expect(dart(at(single, 270)), (points: 11, label: '11'));
    expect(dart(at(single, 342)), (points: 5, label: '5'));
    // Each wedge is 18° wide, centered on its number: 8° off 20 is still 20, 10° off is 1.
    expect(dart(at(single, 8)).points, 20);
    expect(dart(at(single, 10)).points, 1);
    expect(dart(at(single, -10)).points, 5);
  });

  test('darts: bulls, trebles, doubles, and off the scoring area', () {
    expect(dartScore(0, 0), (points: 50, label: 'Bull'));
    expect(dartScore(0.01, 0), (points: 25, label: '25'));
    expect(dartScore(0, (DartRings.trebleIn + DartRings.trebleOut) / 2), (points: 60, label: 'T20'));
    expect(dart(at((DartRings.doubleIn + DartRings.doubleOut) / 2, 180)), (points: 6, label: 'D3'));
    expect(dartScore(0, (DartRings.doubleOut + DartRings.board) / 2), (points: 0, label: 'Out'));
    expect(dartScore(0.3, 0.3), (points: 0, label: 'Miss'));
  });

  test('axes: the rings, the bullseye and the killshots, counting the best part of the edge', () {
    expect(axeScore(0, 0, true), (points: 6, label: 'Bull'));
    expect(axeScore(0.12, 0, true).points, 4);
    expect(axeScore(0.22, 0, true).points, 3);
    expect(axeScore(0.32, 0, true).points, 2);
    expect(axeScore(0.42, 0, true).points, 1);
    expect(axeScore(0.6, 0, true), (points: 0, label: 'Board'));
    expect(axeScore(1.2, 0, true), (points: 0, label: 'Wall'));
    // An edge whose middle is just outside the bull still touches it, so it counts as one.
    expect(axeScore(0, AxeTarget.rings[0].r + AxeTarget.blade / 2 - 0.01, true).points, 6);
    expect(axeScore(0, AxeTarget.rings[0].r + AxeTarget.blade / 2 + 0.01, true).points, 4);
    const k = AxeTarget.kill;
    expect(axeScore(k.u, k.v, true), (points: 8, label: 'Killshot'));
    expect(axeScore(-k.u, k.v, true), (points: 8, label: 'Killshot'));
    // One that bounced off scores nothing, even dead center.
    expect(axeScore(0, 0, false), (points: 0, label: 'Drop'));
    expect(barScore(BarGame.axe, 0, 0, true).points, 6);
    expect(barScore(BarGame.darts, 0, 0, false).points, 50);
  });

  test('the best rounds there are: three treble twenties, five killshots', () {
    final t20 = dartScore(0, (DartRings.trebleIn + DartRings.trebleOut) / 2).points;
    expect(t20 * barRound[BarGame.darts]!, 180);
    expect(AxeTarget.kill.points * barRound[BarGame.axe]!, 40);
    expect(bestRound[BarGame.darts], 180);
    expect(bestRound[BarGame.axe], 40);
  });

  test('the meter runs up and down, and back up again', () {
    expect(meterAt(0, 1), 0);
    expect(meterAt(0.5, 1), 0.5);
    expect(meterAt(1, 1), 1);
    expect(meterAt(1.25, 1), closeTo(0.75, 1e-9));
    expect(meterAt(2.25, 1), closeTo(0.25, 1e-9));
  });

  test(
    'a dart let go in the green lands within a centimeter and a half of the aim; off it, soft drops and hard sails high',
    () {
      final g = barGreen[BarGame.darts]!;
      for (final p in [g.at - g.width / 2, g.at, g.at + g.width / 2]) {
        final l = landing(BarGame.darts, 0, 0.103, p);
        expect((l.v - 0.103).abs(), lessThanOrEqualTo(0.0151), reason: 'at $p');
      }
      // Aimed at treble 20 in the green, it's a treble 20.
      final l = landing(BarGame.darts, 0, 0.103, g.at);
      expect(dartScore(l.u, l.v).label, 'T20');
      expect(
        landing(BarGame.darts, 0, 0, 0.2).v,
        lessThan(-0.4),
        reason: 'thrown far too soft, it drops well under the board',
      );
      expect(
        landing(BarGame.darts, 0, 0, 1).v,
        greaterThan(DartRings.board),
        reason: 'thrown as hard as it goes, it sails over',
      );
      // The hand's own miss is small.
      final j = landing(BarGame.darts, 0, 0, g.at, (1, -1));
      expect(j.u.abs() <= 0.006 && j.v.abs() <= 0.006, isTrue);
    },
  );

  test('an axe let go in the green sticks where it was aimed; off the green it bounces off', () {
    final g = barGreen[BarGame.axe]!;
    for (final p in [g.at - g.width / 2, g.at, g.at + g.width / 2]) {
      expect(landing(BarGame.axe, 0, 0, p).stick, isTrue, reason: 'at $p');
    }
    expect(landing(BarGame.axe, 0, 0, g.at - g.width).stick, isFalse);
    expect(landing(BarGame.axe, 0, 0, g.at + g.width).stick, isFalse);
    final l = landing(BarGame.axe, 0, 0, g.at);
    expect(axeScore(l.u, l.v, true).points, 6);
    // Aimed off the back wall (into the floor), nothing sticks however it's thrown.
    expect(onBackWall(0, -1.45), isFalse);
    expect(landing(BarGame.axe, 0, -1.45, g.at).stick, isFalse);
  });

  test('the office only passes on throws someone could make', () {
    bool ok({Object? game = 'darts', Object? u = 0, Object? v = 0, Object? n = 1}) =>
        tossOk(game: game, u: u, v: v, n: n);
    expect(ok(), isTrue);
    for (final game in BarGame.values) {
      expect(ok(game: game.wire, n: barRound[game]), isTrue);
      expect(ok(game: game.wire, n: barRound[game]! + 1), isFalse);
    }
    expect(ok(game: 'bowling'), isFalse);
    expect(ok(n: 0), isFalse);
    expect(ok(n: 1.5), isFalse);
    expect(ok(u: double.nan), isFalse);
    expect(ok(v: double.infinity), isFalse);
    expect(ok(u: '0'), isFalse);
    expect(ok(v: 9), isFalse);
  });
}
