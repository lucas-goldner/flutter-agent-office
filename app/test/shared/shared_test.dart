import 'dart:math' as math;

import 'package:agent_office/shared/shared.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('avatar', () {
    test('lookFromSeed gives the same looks as the TS', () {
      // Expected values from running src/shared/avatar.ts under node.
      const expected = {
        '': [5, 2, 5],
        'a': [4, 7, 5],
        'alice': [7, 4, 4],
        'Bob': [4, 2, 2],
        'peer-123': [4, 6, 1],
        '日本語': [6, 9, 4],
        '🐶dog': [0, 3, 4],
        'Lucas Goldner': [4, 5, 1],
      };
      expected.forEach((seed, v) {
        expect(lookFromSeed(seed), Look(skin: v[0], hair: v[1], style: v[2]), reason: seed);
      });
      expect(lookFromSeed('x' * 100), const Look(skin: 5, hair: 4, style: 6));
    });

    test('sanitizeLook keeps what is valid', () {
      const fb = Look(skin: 1, hair: 1, style: 1);
      expect(sanitizeLook({'skin': 3, 'hair': 99, 'style': 2.0}, fb), const Look(skin: 3, hair: 1, style: 2));
      expect(sanitizeLook('nope', fb), fb);
      expect(sanitizeLook({'skin': 1.5}, fb).skin, 1);
    });
  });

  group('layout', () {
    test('desks and bean bags', () {
      expect(desks.length, 16);
      expect(desks.first.id, 'desk-1');
      expect(beanbags.length, 12);
      expect(beanbags.every((b) => b.beanbag), isTrue);
      expect(deskById['beanbag-3']!.rotY, math.pi / 2);
      expect(nextFreeSeat((id) => id != 'desk-5')!.id, 'desk-5');
      expect(beanbagsOut((id) => id.startsWith('desk-')), {'beanbag-1'});
    });

    test('seatAt matches the TS', () {
      final c0 = seatAt('couch:0')!;
      expect(c0.key, 'couch:0');
      expect(c0.x, closeTo(10.45, 1e-12));
      expect(c0.z, closeTo(1.2, 1e-12));
      expect(seatAt('couch:2')!.z, closeTo(-1.2, 1e-12));
      expect(seatAt('couch:3'), isNull);
      expect(seatAt('nope:0'), isNull);
      expect(seatAt('couch'), isNull);
      final bench = seatAt('bench:1')!;
      expect(bench.x, closeTo(-8.5, 1e-12));
      expect(bench.z, closeTo(13.6, 1e-12));
      final boss = seatAt('boss-chair:0')!;
      expect((boss.x, boss.y, boss.z), (14.0, 3.0, 11.25));
      final lb = seatAt('lounge-beanbag-1:0')!;
      expect(lb.x, closeTo(12.416084701344353, 1e-12));
      expect(lb.z, closeTo(3.5543895454249568, 1e-12));
      expect(lb.rotY, closeTo(2.145868616527287, 1e-12));
    });

    test('elevatorSpot is inside the car, with an injectable Random', () {
      final r = math.Random(7);
      for (var i = 0; i < 50; i++) {
        final p = elevatorSpot(r);
        expect(inElevator(p.x, p.z), isTrue);
      }
    });
  });

  group('floors', () {
    test('normalizeRepo matches the TS', () {
      const cases = {
        'owner/repo': 'owner/repo',
        'https://github.com/Owner/Repo.git': 'Owner/Repo',
        'git@github.com:a-b/c.d.git': 'a-b/c.d',
        'ssh://git@github.com/o/r/issues/12?x#y': 'o/r',
        '-bad/repo': null,
        'o/..': null,
        'justone': null,
        'https://gitlab.com/o/r': null,
        ' o/r/ ': 'o/r',
      };
      cases.forEach((input, want) => expect(normalizeRepo(input), want, reason: input));
      expect(normalizeRepo(42), isNull);
      expect(normalizeRepo('a/${'b' * 300}'), isNull);
    });

    test('floorPalette wraps both ways', () {
      expect(floorPalette(0).name, 'Maple');
      expect(floorPalette(11).name, 'Mint');
      expect(floorPalette(-1).name, 'Teal');
      expect(sameRepo('A/B', 'a/b'), isTrue);
      expect(sameRepo(null, 'a/b'), isFalse);
    });
  });

  group('dog', () {
    const s = DogState(name: 'Rex', coat: 0, path: [(0, 0), (3, 4), (3, 10)], speed: 2, elapsed: 0, act: DogAct.sit, face: 1.5);

    test('dogAt walks the path like the TS', () {
      final want = [
        (0.0, 0.0, 0.6435011087932844, true),
        (1.2000000000000002, 1.6, 0.6435011087932844, true),
        (3.0, 4.0, 0.0, true),
        (3.0, 7.0, 0.0, true),
        (3.0, 10.0, 1.5, false),
      ];
      final ts = [0.0, 1.0, 2.5, 4.0, 10.0];
      for (var i = 0; i < ts.length; i++) {
        final p = dogAt(s, ts[i]);
        expect(p.x, closeTo(want[i].$1, 1e-12));
        expect(p.z, closeTo(want[i].$2, 1e-12));
        expect(p.heading, closeTo(want[i].$3, 1e-12));
        expect(p.moving, want[i].$4);
      }
      expect(legSeconds(s.path, s.speed), closeTo(5.5, 1e-12));
    });

    test('dogDefaults and cleanDogName', () {
      expect(dogDefaults('floor-1'), (name: 'Cookie', coat: 2));
      expect(dogDefaults('main'), (name: 'Pancake', coat: 5));
      expect(dogDefaults('ƒloor🐶'), (name: 'Pancake', coat: 0));
      expect(cleanDogName('  Re\u0001x  '), 'Rex');
      expect(cleanDogName('x' * 40).length, dogNameMax);
    });
  });

  group('decor, sun, search, whiteboard', () {
    test('sanitizePlacement matches the TS', () {
      final r = sanitizePlacement({'url': 'https://example.com/a.png', 'wall': 'east', 'u': 12, 'y': 6, 'w': 2, 'h': 1, 'frame': 3, 'title': ' Hi\u0001there '});
      expect(r.error, isNull);
      expect(r.placement!.toJson(), {'url': 'https://example.com/a.png', 'title': 'Hi there', 'wall': 'east', 'u': 11.78, 'y': 5.18, 'w': 2, 'h': 1, 'frame': 3});
      expect(sanitizePlacement({'url': 'ftp://x/y', 'wall': 'east'}).error, 'Only http and https links can hang on the wall');
      expect(sanitizePlacement({'url': 'https://x/y', 'wall': 'up'}).error, 'Pick a wall to hang it on');
      expect(wallTop(Side.south, 12), closeTo(Loft.y + Loft.height, 1e-12));
    });

    test('sunPosition matches the TS', () {
      final p = sunPosition(1700000000000, 35.68, 139.69);
      expect(p.el, closeTo(0.16629403761208314, 1e-9));
      expect(p.az, closeTo(2.1097205198758733, 1e-9));
    });

    test('search helpers', () {
      expect(searchKey('  Hello\t  World '), 'hello world');
      final long = '${'a' * 300} needle ${'b' * 300}';
      final s = snippet(long, 'needle');
      expect(s.startsWith('…') && s.endsWith('…'), isTrue);
      expect(s.contains('needle'), isTrue);
    });

    test('whiteboard merge rules', () {
      WbElement el(String id, int v, num nonce, [String? index]) =>
          WbElement({'id': id, 'type': 'rectangle', 'version': v, 'versionNonce': nonce, 'index': ?index, 'strokeColor': '#000'});
      expect(newer(el('a', 2, 5), el('a', 1, 1)), isTrue);
      expect(newer(el('a', 1, 1), el('a', 1, 5)), isTrue);
      expect(newer(el('a', 1, 5), el('a', 1, 1)), isFalse);
      expect(newer(el('a', 1, 5), null), isTrue);
      expect(checkElement({'id': 'a', 'type': 'selection', 'version': 1, 'versionNonce': 1}), isNull);
      expect(checkElement({'id': 'a b', 'type': 'line', 'version': 1, 'versionNonce': 1}), isNull);
      expect(checkElement({'id': 'a', 'type': 'line', 'version': 1.5, 'versionNonce': 1}), isNull);
      final ok = checkElement({'id': 'a', 'type': 'line', 'version': 3, 'versionNonce': 9, 'points': [[0, 0]]})!;
      expect(ok.raw['points'], [[0, 0]]);
      final sorted = [el('c', 1, 1), el('b', 1, 1, 'a1'), el('a', 1, 1, 'a0')]..sort(byIndex);
      expect(sorted.map((e) => e.id), ['a', 'b', 'c']);
    });
  });
}
