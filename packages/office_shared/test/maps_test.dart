// The shared part of tests/maps.test.ts (a worker's clock is the server's, and the docs/maps copies
// aren't in this repository).
import 'dart:convert';
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

double hypot(double a, double b) => math.sqrt(a * a + b * b);

List<CustomMap> check(List<(String, Object?)> files) =>
    checkCustomMaps([for (final (file, json) in files) (file: file, json: json)]);

Map<String, String> whyOf(List<CustomMap> checked) => {for (final m in checked) m.file: m.error ?? ''};

void main() {
  test('every built-in map places every seat the office has, by the same ids', () {
    for (final config in builtinMaps) {
      final plan = planMap(config);
      expect(plan.byId.keys.toSet(), deskById.keys.toSet(), reason: "${config['id']} has the office's seats");
      for (final MapEntry(key: id, value: d) in plan.byId.entries) {
        final office = deskById[id]!;
        expect(d.station, office.station, reason: '$id is a kiosk on both');
        expect(d.room, office.room, reason: '$id is a meeting chair on both');
      }
    }
  });

  test('in the castle every worker can walk from its seat to the door and to the front of the line', () {
    final plan = planOf('castle');
    final nav = NavGrid(plan.bounds, plan.obstacles!);
    expect(plan.lineup.length, greaterThanOrEqualTo(4), reason: 'a line in front of the throne');
    for (final spot in plan.lineup) {
      expect(nav.walkable(spot.x, spot.z), isTrue, reason: "the line's spot at (${spot.x}, ${spot.z}) is clear");
    }
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
      for (final to in [plan.door, for (final s in plan.lineup) (x: s.x, z: s.z)]) {
        final way = nav.wayFrom(d, (to.x, to.z));
        clear(way, 1, '${d.id} going');
        expect(
          pathLength(way),
          lessThan(3 * hypot(to.x - d.x, to.z - d.z) + 10),
          reason: "${d.id} doesn't go the long way round",
        );
        final back = nav.wayTo((to.x, to.z), d);
        clear(back.sublist(0, back.length - 1), 0, '${d.id} coming back');
      }
    }
    // The throne is a seat of its own, somewhere you can sit only on the castle's floors.
    expect(plan.throne, isNotNull);
    expect(seatHereOn(plan, 'throne:0', false), isNotNull);
    expect(seatHereOn(plan, 'couch:0', false), isNull);
    expect(seatHereOn(officePlan, 'throne:0', false), isNull);
    expect(seatHereOn(officePlan, 'couch:0', false), isNotNull);
  });

  test('a custom map extends a built-in one, changing only what it gives', () {
    final [mine] = check([
      (
        'mine.json',
        {
          'id': 'mine',
          'name': 'My hall',
          'extends': 'castle',
          'boards': {
            'issues': {'z': -21},
          },
          'lineup': {'count': 3},
        },
      ),
    ]);
    expect(mine.error, isNull);
    final plan = planOf('mine', [mine]);
    final castle = planOf('castle');
    expect(plan.name, 'My hall');
    expect(plan.boards[BoardKey.issues]!.z, -21);
    expect(
      plan.boards[BoardKey.issues]!.x,
      castle.boards[BoardKey.issues]!.x,
      reason: 'the rest of the board stays put',
    );
    expect(plan.lineup.length, 3);
    expect(
      [for (final d in plan.desks) (d.id, d.x, d.z, d.rotY, d.label)],
      [for (final d in castle.desks) (d.id, d.x, d.z, d.rotY, d.label)],
    );
    expect(mapChoices([mine]).any((c) => c.id == 'mine' && c.custom && c.error == null), isTrue);
    // Its config comes back whole, what it extends filled in, and still says what it extends.
    expect(mine.config!['extends'], 'castle');
    expect(mine.config!['tables'], castleMap['tables']);
  });

  test("a map that can't be used says why, and the building stays on the office", () {
    final checked = check([
      ('office.json', {'id': 'bad-office', 'name': 'x', 'extends': 'office'}),
      (
        'small.json',
        {
          'id': 'small',
          'name': 'Small',
          'extends': 'castle',
          'tables': [
            {'x': 0, 'z': 0, 'length': 4, 'seats': 2},
          ],
        },
      ),
      (
        'far.json',
        {
          'id': 'far',
          'name': 'Far',
          'extends': 'castle',
          'door': {'x': 99, 'z': 0},
        },
      ),
      (
        'thing.json',
        {
          'id': 'thing',
          'name': 'Thing',
          'extends': 'castle',
          'props': [
            {'kind': 'spaceship', 'x': 0, 'z': 0},
          ],
        },
      ),
      ('dupe.json', {'id': 'castle', 'name': 'Castle 2', 'extends': 'castle'}),
      ('loop.json', {'id': 'loop', 'name': 'Loop', 'extends': 'loop'}),
      (
        'low.json',
        {
          'id': 'low',
          'name': 'Low',
          'extends': 'castle',
          'hall': {'height': 9},
        },
      ),
    ]);
    final why = whyOf(checked);
    expect(why['office.json'], contains('office is built in code'));
    expect(why['small.json'], contains('seat 4, and a map needs 32'));
    expect(why['far.json'], contains('outside the hall'));
    expect(why['thing.json'], contains('spaceship'));
    expect(why['dupe.json'], contains('built-in map'));
    expect(why['loop.json'], contains('extends itself'));
    expect(why['low.json'], contains("(a banner) reaches 11.2 m up, over the hall's 9 m walls"));
    expect(identical(planOf('small', checked), officePlan), isTrue);
    expect(identical(planOf('nowhere'), officePlan), isTrue);
  });

  test("a custom map can't ask a browser to build what would hang it, and says why", () {
    const brazier = {'kind': 'brazier', 'x': 0, 'z': 0};
    Map<String, dynamic> castleWith(String id, Map<String, dynamic> more) => {
      'id': id,
      'name': id,
      'extends': 'castle',
      ...more,
    };
    final checked = check([
      (
        'thin.json',
        castleWith('thin', {
          'props': [
            {'kind': 'window', 'x': 0, 'z': -29.9, 'y': 1, 'width': 0},
          ],
        }),
      ),
      (
        'steps.json',
        castleWith('steps', {
          'throne': {
            'dais': {'steps': 1e9},
          },
        }),
      ),
      ('many.json', castleWith('many', {'props': List.filled(5000, brazier)})),
      (
        'crowd.json',
        castleWith('crowd', {
          'tables': [
            {'x': 0, 'z': 0, 'length': 20, 'seats': 40},
          ],
        }),
      ),
      (
        'word.json',
        castleWith('word', {
          'props': [
            {'kind': 'torch', 'x': -12.9, 'z': 0, 'y': 'high'},
          ],
        }),
      ),
      ('spaced.json', castleWith(' spaced ', {})),
      (
        'sides.json',
        castleWith('sides', {
          'tables': [
            {'x': 0, 'z': 0, 'length': 20, 'seats': 12, 'sides': 'left'},
          ],
        }),
      ),
      (
        'pillar.json',
        castleWith('pillar', {
          'herald': {'x': -10.4, 'z': -18},
        }),
      ),
      (
        'line.json',
        castleWith('line', {
          'lineup': {'x': 6.8, 'z': -12},
        }),
      ),
    ]);
    final why = whyOf(checked);
    expect(why['thin.json'], matches(RegExp(r'props\[\d+\]\.width should be between')));
    expect(why['steps.json'], contains('throne.dais.steps should be between 0 and 10'));
    expect(why['many.json'], contains('5000 props, and a map can have 400'));
    expect(why['crowd.json'], contains('seats should be between 1 and 12'));
    expect(why['word.json'], contains('.y should be a number'));
    expect(why['spaced.json'], contains('id should be up to 40 lowercase'));
    expect(why['sides.json'], contains('sides should be "both", "inner" or "outer"'));
    expect(why['pillar.json'], contains('the herald (-10.4, -18.0) is inside something'));
    expect(why['line.json'], contains('lineup spot 1 (6.8, -12.0) is inside something'));
  });

  test('a custom map takes away what it extends with null, and merges no prototype keys', () {
    final [plain] = check([
      (
        'plain.json',
        jsonDecode(
          '{"id":"plain","name":"Plain","extends":"castle","throne":null,"herald":null,"lineup":null,"door":{"__proto__":{"rotY":1.2}}}',
        ),
      ),
    ]);
    expect(plain.error, isNull);
    final plan = planOf('plain', [plain]);
    expect(plan.throne, isNull);
    expect(plan.herald, isNull);
    expect(plan.lineup, isEmpty);
    expect((plain.config!['door'] as Map).containsKey('__proto__'), isFalse);
    // With no dais given, the throne sits on the default one, the height the plan says.
    final [low] = check([
      (
        'low.json',
        {
          'id': 'low',
          'name': 'Low',
          'extends': 'castle',
          'throne': {'dais': null},
        },
      ),
    ]);
    expect(low.error, isNull);
    final p = planOf('low', [low]);
    expect(p.dais, defaultDais);
    expect(p.throne!.y, defaultDais.height);
  });

  test('a custom map goes over the wire as it is', () {
    final [mine] = check([
      ('mine.json', {'id': 'mine', 'name': 'Mine', 'extends': 'castle'}),
    ]);
    final state = MapState(
      pick: 'mine',
      custom: [
        mine,
        const CustomMap(file: 'bad.json', error: 'it needs an id'),
      ],
    );
    final back = MapState.fromJson(jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>);
    expect(back.custom.length, 2);
    expect(back.custom[1].error, 'it needs an id');
    expect(planOf('mine', back.custom).name, 'Mine');
    expect(isMapChoice('mine', back.custom), isTrue);
    expect(isMapChoice('castle'), isTrue);
    expect(isMapChoice('nope'), isFalse);
  });
}
