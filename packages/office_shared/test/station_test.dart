// Port of tests/station.test.ts: the space station's plan, what's cut through its hull, its airlock,
// the script that ejects workers through it, and where whoever's been ejected drifts to.
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

double hypot(double a, double b) => math.sqrt(a * a + b * b);

void main() {
  test('on the station every worker can walk from its seat to the hatch, the line and the airlock', () {
    final plan = planOf('station');
    expect(plan.style, PlanStyle.station);
    final nav = NavGrid(plan.bounds, plan.obstacles!);
    final lock = plan.airlock!;
    expect(nav.walkable(lock.front.$1, lock.front.$2), isTrue, reason: 'the spot in front of the airlock is clear');
    expect(plan.lineup.length, greaterThanOrEqualTo(4));
    void clear(List<Pt> way, int skip, String what) {
      for (var i = skip + 1; i < way.length; i++) {
        final (x0, z0) = way[i - 1];
        final (x1, z1) = way[i];
        final n = (hypot(x1 - x0, z1 - z0) / 0.2).ceil();
        for (var k = 0; k <= n; k++) {
          final x = x0 + ((x1 - x0) * k) / n;
          final z = z0 + ((z1 - z0) * k) / n;
          expect(nav.walkable(x, z), isTrue, reason: '$what walks into something at ($x, $z)');
        }
      }
    }

    for (final d in plan.byId.values) {
      for (final to in [
        plan.door,
        for (final s in plan.lineup) (x: s.x, z: s.z),
        (x: lock.front.$1, z: lock.front.$2),
      ]) {
        final way = nav.wayFrom(d, (to.x, to.z));
        clear(way, 1, '${d.id} going');
        expect(
          pathLength(way),
          lessThan(3 * hypot(to.x - d.x, to.z - d.z) + 10),
          reason: "${d.id} doesn't go the long way round",
        );
      }
    }
    final post = plan.sendHome!.escort!.post;
    expect(nav.walkable(post.x, post.z), isTrue);
    expect(plan.throne, isNotNull, reason: 'a captain’s chair to sit in');
  });

  test(
    'the airlock is in the hull, its chamber outside it, and nothing cut through a wall runs into anything else',
    () {
      final plan = planOf('station');
      final lock = plan.airlock!;
      final b = plan.bounds;
      expect(lock.wall, WallSide.east);
      expect(lock.out, (1.0, 0.0));
      expect(lock.door.$1, b.maxX, reason: 'its inner door is in the east wall');
      expect(
        lock.front.$1 < b.maxX && lock.chamber.$1 > b.maxX + hullThickness && lock.hatch.$1 > lock.chamber.$1,
        isTrue,
      );
      expect((lock.hatch.$1 - (b.maxX + hullThickness + AirlockSize.depth)).abs(), lessThan(1e-9));
      final openings = plan.openings!;
      expect(openings.where((o) => o.kind == OpeningKind.door).length, 1);
      expect(openings.where((o) => o.kind == OpeningKind.airlock).length, 1);
      expect(
        openings.where((o) => o.kind == OpeningKind.viewport).length,
        11,
        reason: 'three forward, four down each side',
      );
      for (final o in openings) {
        expect(o.y + o.height, lessThan(plan.height));
        for (final p in openings) {
          if (!identical(p, o) && p.wall == o.wall)
            expect((p.u - o.u).abs(), greaterThanOrEqualTo((p.width + o.width) / 2));
        }
      }
      // Either side of the airlock, a window to watch from.
      final beside = openings.where(
        (o) => o.wall == WallSide.east && o.kind == OpeningKind.viewport && (o.u - lock.door.$2).abs() < 8,
      );
      expect(beside.length, 2);
      // A board never hangs over a window.
      for (final board in plan.boards.values) {
        final wall = board.x < 0 ? WallSide.west : WallSide.east;
        for (final o in openings) {
          if (o.wall == wall) expect((o.u - board.z).abs(), greaterThan((o.width + board.width) / 2));
        }
      }
    },
  );

  test('a worker sent home on the station is ejected, and kept', () {
    final send = planOf('station').sendHome!;
    expect(send.keeps, isTrue);
    expect(send.escort, isNotNull);
    final does = [for (final s in send.steps) s.kind];
    expect(does.indexOf(SendHomeStepKind.eject), greaterThan(does.indexOf(SendHomeStepKind.walk)));
    expect(send.steps.firstWhere((s) => s.kind == SendHomeStepKind.walk).toJson(), {'do': 'walk', 'to': 'airlock'});
    // The castle still locks its own up, and the office keeps nobody.
    expect(planOf('castle').sendHome!.keeps, isTrue);
    expect(planOf('office').sendHome, isNull);
  });

  test('whoever is ejected drifts out from the hatch, clear of the hull, the same for everyone', () {
    final lock = planOf('station').airlock!;
    const h = 3600000;
    double far(Drift d) {
      final dx = d.x - lock.hatch.$1;
      final dy = d.y - 1.3;
      final dz = d.z - lock.hatch.$2;
      return math.sqrt(dx * dx + dy * dy + dz * dz);
    }

    final sides = <int>{};
    for (var i = 0; i < 60; i++) {
      final id = 'worker-$i';
      expect(adrift(lock, id, 5000), adrift(lock, id, 5000));
      var last = 0.0;
      for (final age in [0, 20000, 120000, h, 6 * h, 48 * h, 2000 * h]) {
        final d = adrift(lock, id, age);
        expect(d.x, greaterThan(lock.hatch.$1 + 2), reason: '$id is out past the hatch at $age ms');
        expect(
          far(d) > Adrift.near - 1.5 && far(d) < Adrift.far + 1.5,
          isTrue,
          reason: '$id is ${far(d)} m off at $age ms',
        );
        expect(far(d), greaterThan(last - 1.5), reason: "$id doesn't come back");
        last = far(d);
      }
      final d = adrift(lock, id, 10 * 60000);
      expect((d.z - lock.hatch.$2).abs(), greaterThan(3), reason: '$id is off to one side');
      sides.add((d.z - lock.hatch.$2).sign.toInt());
    }
    expect(sides.length, 2, reason: 'some to each side');
    expect(adrift(lock, 'a', 60000), isNot(adrift(lock, 'b', 60000)));
    expect(adriftFrom(3), 0);
    expect(adriftFrom(Adrift.shown + 12), 12);
  });

  test('a station of your own changes only what it gives, and says why when it can’t be built', () {
    Map<String, dynamic> sendHome(List<Object> steps) => {
      'escort': {
        'post': {'x': 13.3, 'z': 15.3},
      },
      'steps': steps,
    };
    Map<String, dynamic> station(String id, Map<String, dynamic> more, [String base = 'station']) => {
      'id': id,
      'name': id,
      'extends': base,
      ...more,
    };
    final checked = checkCustomMaps([
      (
        file: 'mine.json',
        json: station('mine', {
          'airlock': {'x': -14.6, 'z': 13},
          'props': [
            {'kind': 'viewport', 'x': 0, 'z': -29, 'y': 1.5, 'width': 8, 'height': 4},
          ],
          'sendHome': sendHome([
            {'do': 'fetch'},
            {'do': 'eject'},
            {'do': 'return'},
          ]),
        }),
      ),
      (
        file: 'pillar.json',
        json: station('pillar', {
          'props': [
            {'kind': 'pillar', 'x': 0, 'z': 0},
          ],
        }),
      ),
      (
        file: 'clash.json',
        json: station('clash', {
          'props': [
            {'kind': 'viewport', 'x': 15, 'z': 12, 'width': 4},
          ],
        }),
      ),
      (
        file: 'afloat.json',
        json: station('afloat', {
          'props': [
            {'kind': 'viewport', 'x': 0, 'z': 0},
          ],
        }),
      ),
      (
        file: 'wide.json',
        json: station('wide', {
          'props': [
            {'kind': 'viewport', 'x': 13, 'z': -29, 'width': 6},
          ],
        }),
      ),
      (
        file: 'tall.json',
        json: station('tall', {
          'props': [
            {'kind': 'viewport', 'x': 0, 'z': -29, 'y': 4, 'height': 3.5},
          ],
        }),
      ),
      (file: 'sealed.json', json: station('sealed', {'airlock': null})),
      (
        file: 'dug.json',
        json: station('dug', {
          'dungeon': {
            'x': 0,
            'z': 0,
            'width': 10,
            'length': 10,
            'depth': 4,
            'stairs': {'x': 0, 'z': -4},
            'cells': [
              {'x': 0, 'z': 4, 'rotY': 3.1416, 'width': 4, 'depth': 3},
            ],
          },
        }),
      ),
      (
        file: 'moat.json',
        json: station('moat', {
          'airlock': {'x': 12.6, 'z': 0},
        }, 'castle'),
      ),
      (
        file: 'door.json',
        json: station('door', {
          'airlock': {'x': 1, 'z': 28.6},
        }),
      ),
      (file: 'quiet.json', json: station('quiet', {'sendHome': null})),
    ]);
    final why = {for (final m in checked) m.file: m.error ?? ''};
    expect(why['mine.json'], '');
    final mine = planOf('mine', checked);
    expect(mine.airlock!.wall, WallSide.west);
    expect(mine.airlock!.out, (-1.0, 0.0));
    expect(
      mine.openings!.where((o) => o.kind == OpeningKind.viewport).length,
      1,
      reason: 'a list replaces the whole list',
    );
    expect(
      why['pillar.json'],
      contains('a "pillar", which isn’t a kind of prop a station-style map has (rib, viewport'),
    );
    expect(why['clash.json'], contains('(a viewport) runs into the airlock in the east wall'));
    expect(why['afloat.json'], contains("(a viewport) should be on a wall: it's 15.0 m from the nearest"));
    expect(why['wide.json'], contains('runs off the end of the north wall'));
    expect(why['tall.json'], contains("reaches 7.5 m up, and the hall's walls are 7.6 m"));
    expect(why['sealed.json'], contains('sendHome walks workers to the airlock, and the map has no airlock'));
    expect(why['dug.json'], contains('a station-style map has no dungeon'));
    expect(why['moat.json'], contains('only a station-style map has an airlock'));
    expect(why['door.json'], contains('the airlock runs into the way in in the south wall'));
    expect(why['quiet.json'], '');
    expect(planOf('quiet', checked).sendHome, isNull);
  });
}
