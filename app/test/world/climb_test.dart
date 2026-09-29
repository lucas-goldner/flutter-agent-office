// Between the floors: the ladder, the fire pole, and the holes and railings they go through.
import 'dart:math' as math;

import 'package:agent_office/world/climb.dart';
import 'package:agent_office/world/collider.dart';
import 'package:agent_office/world/office/stack_plan.dart';
import 'package:agent_office/world/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';

List<Collider> _floor() => stackColliders(const StackState(index: 1, count: 3, up: 'c', down: 'a'));

double _area(List<PlanRect> rs) => rs.fold(0, (a, r) => a + (r.maxX - r.minX) * (r.maxZ - r.minZ));

class _Trip {
  final List<(Way, Grip, Arrival)> travels = [];
  final List<String> sounds = [];
  final List<(Grip, bool)> done = [];
  String? up = 'Upstairs';
  String? down = 'Downstairs';

  ClimbHooks hooks() => ClimbHooks(
    floorThere: (w) => w > 0 ? up : down,
    travel: (w, how, at) => travels.add((w, how, at)),
    sound: (k, _) => sounds.add(k),
    done: (how, landed) => done.add((how, landed)),
  );
}

void run(PlayerController p, double seconds, {double dt = 1 / 60}) {
  for (var t = 0.0; t < seconds; t += dt) {
    p.update(dt);
  }
}

void main() {
  group('cutRect', () {
    test('a hole in the middle leaves the rest, in four pieces', () {
      final r = PlanRect(0, 10, 0, 10);
      final out = cutRect(r, [PlanRect(4, 6, 4, 6)]);
      expect(_area(out), closeTo(96, 1e-9));
      expect(out, hasLength(4));
      for (final o in out) {
        final overlaps = o.minX < 6 && o.maxX > 4 && o.minZ < 6 && o.maxZ > 4;
        expect(overlaps, isFalse, reason: '$o');
      }
    });

    test('no holes, or holes outside it, leave it whole', () {
      expect(_area(cutRect(PlanRect(0, 4, 0, 2), [])), 8);
      expect(cutRect(PlanRect(0, 4, 0, 2), [PlanRect(10, 11, 10, 11)]), hasLength(1));
    });

    test('a hole at the edge is clipped to it', () {
      expect(_area(cutRect(PlanRect(0, 10, 0, 10), [PlanRect(-2, 2, -2, 2)])), closeTo(96, 1e-9));
    });
  });

  group('the stack', () {
    test('on the only floor: a whole floor and a ceiling, no ladder, no pole', () {
      final cs = stackColliders(const StackState());
      expect(cs.where((c) => c.top == 0), hasLength(1));
      expect(cs.where((c) => c.bottom == wallHeight), hasLength(1));
      expect(cs.where((c) => c.top == 99), isEmpty);
      final p = poles.first;
      expect(groundAt(cs, p.x, p.z, 0), 0);
    });

    test('on the bottom floor of two: the ladder and the pole stand there, the floor is whole', () {
      final cs = stackColliders(const StackState(index: 0, count: 2, up: 'b'));
      expect(cs.where((c) => c.top == 99), hasLength(2));
      expect(cs.where((c) => c.top == 0), hasLength(1));
    });

    test('with a floor below, the pole goes down a hole with a railing round three sides', () {
      final cs = stackColliders(const StackState(index: 1, count: 3, up: 'c', down: 'a'));
      final p = poles.first;
      // Standing over the hole there's no floor, only the catch well under it.
      expect(groundAt(cs, p.x, p.z, 0), closeTo(-1.2, 1e-9));
      // A step past the railing, the floor.
      expect(groundAt(cs, p.x + 3, p.z, 0), 0);
      final rails = cs.where((c) => c.top == 1.05).toList();
      expect(rails, hasLength(3));
      // The way in (toward `open`) has no rail across it.
      final gapX = p.x + math.sin(p.open) * Pole.rail, gapZ = p.z + math.cos(p.open) * Pole.rail;
      expect(rails.any((r) => touches(r, gapX, gapZ, 0.05)), isFalse);
      // The ladder's hatch is a trapdoor: you walk over it.
      expect(groundAt(cs, Ladder.hatch.maxX - 0.3, Ladder.z, 0), 0);
    });

    test('hatches open for someone passing through them', () {
      expect(hatchesWanted(Ladder.x, -0.5, Ladder.z).floor, isTrue);
      expect(hatchesWanted(Ladder.x, 0.3, Ladder.z, onLadder: true).floor, isTrue);
      expect(hatchesWanted(Ladder.x, 0.3, Ladder.z).floor, isFalse);
      expect(hatchesWanted(Ladder.x, wallHeight - 1.5, Ladder.z).ceiling, isTrue);
      expect(hatchesWanted(5, -0.5, 5).floor, isFalse);
    });
  });

  group('the ladder', () {
    test('up through the hatch to the floor above, and off onto it', () {
      final p = PlayerController(_floor())..pos.setValues(Ladder.hatch.maxX + 0.3, 0, Ladder.z);
      final trip = _Trip();
      final c = Climber(p, trip.hooks());
      c.grabLadder();
      expect(c.grip, Grip.ladder);
      p.input.forward = true;
      run(p, 5);
      expect(trip.travels, hasLength(1));
      final (way, how, at) = trip.travels.single;
      expect(way, 1);
      expect(how, Grip.ladder);
      expect(at.y, closeTo(ladderTop - storey, 1e-5));
      expect(c.ladder!.waiting, isTrue);
      // The floor above comes: your head's through its floor, and you climb on up by yourself.
      p.input.forward = false;
      c.arrived();
      expect(p.pos.y, closeTo(ladderTop - storey, 1e-5));
      run(p, 3);
      expect(c.active, isFalse);
      expect(trip.done.single, (Grip.ladder, true));
      expect(p.pos.y, 0);
      expect(p.pos.x, closeTo(offLadderX, 1e-5));
    });

    test('on the top floor the hatch will not budge', () {
      final p = PlayerController(_floor());
      final trip = _Trip()..up = null;
      final c = Climber(p, trip.hooks())..grabLadder();
      p.input.forward = true;
      run(p, 5);
      expect(trip.travels, isEmpty);
      expect(trip.sounds.where((s) => s == 'bonk'), hasLength(1));
      expect(p.pos.y, closeTo(ladderTop, 1e-5));
      expect(c.active, isTrue);
    });

    test('down on the bottom floor, S steps you off', () {
      final p = PlayerController(_floor())..pos.setValues(Ladder.hatch.maxX + 0.3, 0, Ladder.z);
      final trip = _Trip()..down = null;
      final c = Climber(p, trip.hooks())..grabLadder();
      p.input.back = true;
      run(p, 1);
      expect(c.active, isFalse);
      expect(trip.travels, isEmpty);
    });

    test('the floor never came: back on this one', () {
      final p = PlayerController(_floor());
      final trip = _Trip();
      final c = Climber(p, trip.hooks())..grabLadder();
      p.input.back = true;
      run(p, 3);
      expect(trip.travels.single.$1, -1);
      c.abort();
      expect(c.active, isFalse);
      expect(p.rig, isNull);
      expect(p.pos.y, 0);
    });
  });

  group('the fire pole', () {
    final spot = poles.first;

    test('down the hole, through the ceiling below, and off out through the railing', () {
      final p = PlayerController(_floor())..pos.setValues(spot.x + 0.2, 0, spot.z + 0.2);
      final trip = _Trip();
      final c = Climber(p, trip.hooks())..slide(spot);
      run(p, 2);
      final (way, how, at) = trip.travels.single;
      expect((way, how), (-1, Grip.pole));
      expect(at.y, closeTo(poleBottom + storey, 1e-5));
      expect(c.sliding, 'slide');
      c.arrived();
      expect(p.pos.y, closeTo(poleBottom + storey, 1e-5));
      run(p, 4);
      expect(c.active, isFalse);
      expect(trip.done.single, (Grip.pole, true));
      // Out past the railing's gap, the way into the hole.
      final r = math.sqrt(math.pow(p.pos.x - spot.x, 2) + math.pow(p.pos.z - spot.z, 2));
      expect(r, closeTo(offPole, 1e-5));
      expect(
        math.atan2(p.pos.x - spot.x, p.pos.z - spot.z),
        closeTo(math.atan2(math.sin(spot.open), math.cos(spot.open)), 1e-5),
      );
    });

    test('onto the bottom floor, a landing on the mat', () {
      final p = PlayerController(_floor())..pos.setValues(spot.x, 0, spot.z + 1);
      final trip = _Trip();
      final c = Climber(p, trip.hooks())..slide(spot);
      run(p, 2);
      trip.down = null;
      c.arrived();
      run(p, 4);
      expect(c.active, isFalse);
      expect(trip.sounds, contains('land'));
      expect(p.pos.y, 0);
    });

    test('a twirl round a pole that goes nowhere', () {
      final p = PlayerController(_floor())..pos.setValues(spot.x, 0, spot.z + 1);
      final c = Climber(p, _Trip().hooks())..twirl(spot);
      run(p, 2);
      expect(c.active, isFalse);
      expect(p.pos.y, 0);
    });

    test('someone else is seen holding on by where they are', () {
      expect(gripOf(Ladder.x, 2, Ladder.z, poles, 0), Grip.ladder);
      expect(gripOf(spot.x + Pole.grip, 1, spot.z, poles, 0), Grip.pole);
      expect(gripOf(spot.x + Pole.grip, 0, spot.z, poles, 0), isNull);
      expect(gripOf(0, 1, 0, poles, 0), isNull);
    });
  });

  test('colliders are mutable where the street moves', () {
    final c = Collider(minX: 0, maxX: 1, minZ: 0, maxZ: 1, top: 0, bottom: -1)..bottom = -2;
    expect(c.bottom, -2);
  });
}
