// The shared part of tests/dungeon.test.ts (the jail that remembers prisoners is the server's).
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void walkableAll(List<Pt> way, bool Function(double x, double z) ok, String what) {
  for (var i = 1; i < way.length; i++) {
    final (x0, z0) = way[i - 1];
    final (x1, z1) = way[i];
    final n = (math.sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0)) / 0.2).ceil();
    for (var k = 0; k <= n; k++) {
      final x = x0 + ((x1 - x0) * k) / n;
      final z = z0 + ((z1 - z0) * k) / n;
      expect(ok(x, z), isTrue, reason: '$what walks into something at ($x, $z)');
    }
  }
}

List<CustomMap> check(List<(String, Map<String, dynamic>)> files) =>
    checkCustomMaps([for (final (file, json) in files) (file: file, json: json)]);

void main() {
  test('the castle has a dungeon, and locks up whoever is sent home in it', () {
    final plan = planOf('castle');
    final d = plan.dungeon!;
    expect(plan.sendHome?.keeps, isTrue);
    expect(plan.sendHome!.escort!.name, 'Kingsguard');
    expect(plan.sendHome!.escort!.below, isTrue, reason: 'on watch down in the dungeon');
    expect(d.floor < -4 && d.ceiling < 0, isTrue);
    expect(d.steps.last.top, d.floor, reason: 'the stairs go all the way down');
    for (var i = 1; i < d.steps.length; i++) {
      expect(d.steps[i - 1].top - d.steps[i].top, lessThan(0.3));
    }
    expect(d.seats.length, greaterThanOrEqualTo(40));
    expect([for (final s in d.seats.take(d.cells.length)) s.cell], [for (var i = 0; i < d.cells.length; i++) i]);
  });

  test(
    'in the castle a worker can be walked from any seat down the stairs to any cell, and the escort back to its post',
    () {
      final plan = planOf('castle');
      final d = plan.dungeon!;
      final hall = NavGrid(plan.bounds, plan.obstacles!);
      final vault = NavGrid(d.bounds, d.obstacles);
      final post = plan.sendHome!.escort!.post;
      expect(vault.walkable(post.x, post.z), isTrue);
      expect(hall.walkable(d.stairs.top.$1, d.stairs.top.$2), isTrue);
      expect(vault.walkable(d.stairs.foot.$1, d.stairs.foot.$2), isTrue);
      for (final seat in plan.desks) {
        final off = hall.wayFrom(seat, d.stairs.top);
        walkableAll(off.sublist(1), hall.walkable, '${seat.id} going to the stairs');
      }
      for (final (i, c) in d.cells.indexed) {
        final down = levelRoute(d, hall, vault, d.stairs.top, false, c.outside, true);
        final at = down.indexOf(d.stairs.start);
        expect(down[at + 1], d.stairs.end, reason: 'down the stairs');
        walkableAll(down.sublist(at + 2), vault.walkable, 'down to cell $i');
        final back = levelRoute(d, hall, vault, c.outside, true, (post.x, post.z), true);
        walkableAll(back, vault.walkable, 'from cell $i back to the post');
      }
      final up = levelRoute(d, hall, vault, (post.x, post.z), true, (0, 0), false);
      expect(up.contains(d.stairs.end) && up.contains(d.stairs.start), isTrue, reason: 'up the stairs');
      expect(up.last, (0.0, 0.0));
    },
  );

  test(
    'a prisoner stays in the seat it was thrown into, and once every seat has been taken the oldest are bones on the heap',
    () {
      final d = planOf('castle').dungeon!;
      final n = d.seats.length;
      expect(prisonSeat(d, 0, 1), d.seats[0]);
      expect(prisonSeat(d, 5, 20), d.seats[5]);
      expect(prisonSeat(d, 0, n + 1), isNull);
      expect(prisonSeat(d, n, n + 1), d.seats[0]);
      expect(prisonSeat(d, 1, n + 1), d.seats[1], reason: 'nobody else moves');
    },
  );

  test('locked up, a worker wastes away: thinner till it starves to death, then it rots to the bone', () {
    const starveMs = 24 * 3600000.0;
    const rotMs = 12 * 3600000.0;
    const at = 1000000;
    int h(int n) => at + n * 3600000;
    ({double thin, bool dead, double rot}) w(int now) => wasting(at, now, starveMs: starveMs, rotMs: rotMs);
    expect(w(at), (thin: 0.0, dead: false, rot: 0.0));
    expect(w(h(12)), (thin: 0.5, dead: false, rot: 0.0));
    expect(w(h(24)), (thin: 1.0, dead: true, rot: 0.0));
    expect(w(h(30)), (thin: 1.0, dead: true, rot: 0.5));
    expect(w(h(100)), (thin: 1.0, dead: true, rot: 1.0));
    expect(w(at - 5000), (thin: 0.0, dead: false, rot: 0.0));
  });

  test(
    'a map of your own can script sending workers home its own way, and says what is wrong with a script that can’t work',
    () {
      Map<String, dynamic> castle(String id, Map<String, dynamic> more) => {
        'id': id,
        'name': id,
        'extends': 'castle',
        ...more,
      };
      final [kind, noEscort, noDungeon, after, place, ok, doorOnly] = check([
        (
          'kind.json',
          castle('kind', {
            'sendHome': {
              'steps': [
                {'do': 'dance'},
              ],
            },
          }),
        ),
        (
          'no-escort.json',
          castle('no-escort', {
            'sendHome': {
              'escort': null,
              'steps': [
                {'do': 'fetch'},
                {'do': 'walk', 'to': 'door'},
              ],
            },
          }),
        ),
        ('no-dungeon.json', castle('no-dungeon', {'dungeon': null})),
        (
          'after.json',
          castle('after', {
            'sendHome': {
              'steps': [
                {'do': 'jail'},
                {'do': 'say', 'text': 'hi'},
              ],
            },
          }),
        ),
        (
          'place.json',
          castle('place', {
            'sendHome': {
              'steps': [
                {'do': 'walk', 'to': 'moon'},
              ],
            },
          }),
        ),
        (
          'ok.json',
          castle('ok', {
            'sendHome': {
              'steps': [
                {'do': 'pack'},
                {'do': 'walk', 'to': 'dungeon', 'run': true},
                {
                  'do': 'say',
                  'text': ['bye', 'oh no'],
                },
                {'do': 'jail'},
              ],
              'starveHours': 0.5,
              'rotHours': 0.25,
            },
          }),
        ),
        (
          'door.json',
          castle('door', {
            'dungeon': null,
            'sendHome': {
              'escort': null,
              'steps': [
                {'do': 'pack'},
                {'do': 'walk', 'to': 'door'},
              ],
            },
          }),
        ),
      ]);
      expect(kind.error, contains('"dance", which isn\'t a step there is'));
      expect(noEscort.error, contains('an escort fetching the worker, and no escort'));
      expect(noDungeon.error, contains('and the map has no dungeon'));
      expect(after.error, contains('locked up by then, so only its escort'));
      expect(place.error, contains('should be one of "door", "stairs"'));
      expect(ok.error, isNull);
      final quick = planOf('ok', [ok]).sendHome!;
      expect(quick.keeps, isTrue);
      expect(quick.starveMs, 30 * 60000);
      expect(quick.rotMs, 15 * 60000);
      expect(doorOnly.error, isNull);
      final out = planOf('door', [doorOnly]);
      expect(out.dungeon, isNull);
      expect(out.sendHome!.keeps, isFalse, reason: 'walked out, not kept');
      final [plain] = check([
        ('plain.json', castle('plain', {'dungeon': null, 'sendHome': null})),
      ]);
      expect(plain.error, isNull);
      expect(planOf('plain', [plain]).sendHome, isNull);
    },
  );

  test('a dungeon has to fit: under the hall, its stairs clear of the tables, its cells clear of each other', () {
    Map<String, dynamic> cells(List<Map<String, dynamic>> extra) => {
      'cells': [
        {'x': -9.1, 'z': 17.6, 'rotY': 0, 'width': 4.6, 'depth': 4},
        ...extra,
      ],
    };
    Map<String, dynamic> castle(String id, Map<String, dynamic> more) => {
      'id': id,
      'name': 'x',
      'extends': 'castle',
      ...more,
    };
    final [outside, table, overlap, steep, ok] = check([
      (
        'outside.json',
        castle('outside', {
          'dungeon': {'x': 10},
        }),
      ),
      (
        'table.json',
        castle('table', {
          'props': [
            {'kind': 'table', 'x': 8.3, 'z': 16, 'width': 1.4, 'length': 3},
          ],
        }),
      ),
      (
        'overlap.json',
        castle('overlap', {
          'dungeon': cells([
            {'x': -8, 'z': 17.6, 'rotY': 0, 'width': 4.6, 'depth': 4},
          ]),
        }),
      ),
      (
        'steep.json',
        castle('steep', {
          'dungeon': {
            'stairs': {'rotY': 0.3},
          },
        }),
      ),
      ('ok.json', castle('mine', {'dungeon': cells([])})),
    ]);
    expect(outside.error, contains('dungeon should be under the hall'));
    expect(table.error, contains('stairs come up through something in the hall'));
    expect(overlap.error, contains('runs into dungeon.cells[0]'));
    expect(steep.error, contains('should be a quarter turn'));
    expect(ok.error, isNull);
    final d = planOf('mine', [ok]).dungeon!;
    expect(d.cells.length, 1);
    expect(d.seats.length, d.cells[0].spots.length);
    for (final s in d.cells[0].spots) {
      expect(s.x > -11.4 && s.x < -6.8 && s.z > 13.6 && s.z < 17.6, isTrue);
    }
    expect(dungeonClear(d, -9.1, 15.6), isFalse);
    expect(dungeonClear(d, -9.1, 19), isTrue);
  });
}
