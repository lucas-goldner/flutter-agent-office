// The thrower at the rooftop bar's dart board and axe lane (features/bargames/controller.ts): stepping
// up and back, aiming with the keys and the mouse, the meter, and throws numbered through a round.

import 'dart:math' as math;

import 'package:agent_office/office/bar_games_play.dart' show greatRound, roundText;
import 'package:agent_office/office/throwing.dart';
import 'package:agent_office/world/bar_games.dart' show tossPop;
import 'package:agent_office/world/person_throw.dart' show Release;
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/bargames.dart';
import 'package:vector_math/vector_math.dart' as vm;

class _Rig {
  double clock = 0;
  final List<BarGame?> holding = [];
  final List<Toss> tosses = [];
  final List<BarGame?> stood = [];
  (BarGame?, double, double)? aimed;
  double wound = 0;
  Release? pending;
  int done = 0;

  late final Thrower thrower = Thrower(
    ThrowHooks(
      holding: holding.add,
      toss: (t, from, turn) => tosses.add(t),
      aim: (g, u, v) => aimed = (g, u, v),
      done: () => done++,
      stand: stood.add,
      windBack: (k) => wound = k,
      letGo: (r) => pending = r,
    ),
    now: () => clock,
    random: math.Random(1),
  );

  /// Draws back for [ms] and lets go, and the arm comes round to let go of it.
  void throwFor(double ms) {
    thrower.windUp();
    clock += ms;
    thrower.letGo();
    pending?.call(vm.Vector3.zero(), 0);
    pending = null;
  }
}

void main() {
  test('stepping up holds a dart, and stepping back puts it down and says so', () {
    final r = _Rig();
    final t = r.thrower..start(BarGame.darts, vm.Vector3.zero(), vm.Vector3(0, 0, -1));
    expect(t.active, isTrue);
    expect(t.playing, BarGame.darts);
    expect(r.holding, [BarGame.darts]);
    expect(t.fov, 24);
    expect(t.panel.value?.title, '🎯 Darts · dart 1 of 3');
    t.update(1 / 60);
    expect(r.aimed?.$1, BarGame.darts, reason: 'the reticle shows where you aim');
    t.stop();
    expect(t.active, isFalse);
    expect(r.holding, [BarGame.darts, null]);
    expect(r.stood.last, isNull);
    expect(r.aimed?.$1, isNull);
    expect(t.panel.value, isNull);
    expect(r.done, 1);
    t.stop();
    expect(r.done, 1, reason: 'stopping twice is once');
  });

  test('the meter runs up and back down, and a throw in the green of it flies', () {
    final r = _Rig();
    final t = r.thrower..start(BarGame.darts, vm.Vector3.zero(), vm.Vector3.zero());
    t.windUp();
    expect(t.doing, ThrowStage.wind);
    r.clock += 1050 * 0.5;
    expect(t.power, closeTo(0.5, 1e-9));
    r.clock += 1050 * 0.5;
    expect(t.power, closeTo(1, 1e-9));
    r.clock += 1050 * 0.25;
    expect(t.power, closeTo(0.75, 1e-9));
    t.putBack();
    expect(t.doing, ThrowStage.aim);

    // In the green: 0.7 of the way up.
    r.throwFor(1050 * barGreen[BarGame.darts]!.at);
    expect(r.tosses, hasLength(1));
    expect(r.tosses.single.n, 1);
    expect(r.tosses.single.stick, isTrue);
    expect(t.doing, ThrowStage.wait);
    expect(t.panel.value, isNotNull);
  });

  test('barely drawn back is no throw at all', () {
    final r = _Rig();
    r.thrower.start(BarGame.axe, vm.Vector3.zero(), vm.Vector3.zero());
    r.throwFor(10);
    expect(r.tosses, isEmpty);
    expect(r.thrower.doing, ThrowStage.aim);
  });

  test('throws are numbered through the round, and the next round starts at one again', () {
    final r = _Rig();
    final t = r.thrower..start(BarGame.darts, vm.Vector3.zero(), vm.Vector3.zero());
    for (var i = 0; i < 4; i++) {
      // Ready again once the last one has gone.
      r.clock += 1000;
      t.update(0.01);
      expect(t.doing, ThrowStage.aim);
      r.throwFor(700);
    }
    expect(r.tosses.map((x) => x.n), [1, 2, 3, 1]);
  });

  test('you can only throw again once the last one has left and you are ready', () {
    final r = _Rig();
    final t = r.thrower..start(BarGame.axe, vm.Vector3.zero(), vm.Vector3.zero());
    r.throwFor(800);
    t.windUp();
    expect(t.doing, ThrowStage.wait);
    r.clock += 1349;
    t.update(0.01);
    expect(t.doing, ThrowStage.wait);
    r.clock += 2;
    t.update(0.01);
    expect(t.doing, ThrowStage.aim);
  });

  test('the keys and the mouse move the aim, only so far off the target', () {
    final r = _Rig();
    final t = r.thrower..start(BarGame.darts, vm.Vector3.zero(), vm.Vector3.zero());
    expect(t.aimV, closeTo(0.103, 1e-9), reason: 'darts start at treble twenty');
    t.update(1, right: true);
    expect(t.aimU, closeTo(0.12, 1e-9));
    t.look(-1e5, 0);
    expect(t.aimU, closeTo(0.02, 1e-9), reason: 'a jump of the mouse counts for 250 px at most');
    for (var i = 0; i < 10; i++) {
      t.look(-250, 0);
    }
    expect(t.aimU, closeTo(-0.32, 1e-9), reason: 'clamped to the reach');
    // The free mouse: straight at the board's middle from out front.
    final f = targetFrame(BarGame.darts);
    final from = vm.Vector3(f.x + f.out.x * 2, f.y, f.z + f.out.z * 2);
    t.pointAt(vm.Ray.originDirection(from, vm.Vector3(-f.out.x, 0, -f.out.z)));
    expect(t.aimU, closeTo(0, 1e-5));
    expect(t.aimV, closeTo(0, 1e-5));
  });

  test('more drinks, more wander', () {
    final r = _Rig();
    final t = r.thrower..start(BarGame.axe, vm.Vector3.zero(), vm.Vector3.zero());
    t.update(0.37);
    final (u0, v0) = t.sway();
    t.drunk = 1;
    final (u1, v1) = t.sway();
    expect(math.sqrt(u1 * u1 + v1 * v1), greaterThan(math.sqrt(u0 * u0 + v0 * v0) * 3));
  });

  test('what a throw says, and what a round says', () {
    expect(tossPop(BarGame.darts, (points: 50, label: 'Bull')), 'BULL!');
    expect(tossPop(BarGame.darts, (points: 0, label: 'Out')), 'Miss');
    expect(tossPop(BarGame.darts, (points: 60, label: 'T20')), 'T20');
    expect(tossPop(BarGame.axe, (points: 8, label: 'Killshot')), 'KILLSHOT!');
    expect(tossPop(BarGame.axe, (points: 0, label: 'Drop')), 'Clank!');
    expect(tossPop(BarGame.axe, (points: 3, label: '3')), '+3');
    expect(greatRound(BarGame.darts, 180), isTrue);
    expect(greatRound(BarGame.darts, 177), isFalse);
    expect(greatRound(BarGame.axe, 30), isTrue);
    expect(roundText(BarGame.darts, 180), 'ONE HUNDRED AND EIGHTY!');
    expect(roundText(BarGame.axe, 21), '21 of 40 with five axes');
  });
}
