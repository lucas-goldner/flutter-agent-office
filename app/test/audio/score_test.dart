// The jukebox's score against the TS client's: music_ref.json is what src/client/music.ts computes
// (regenerate it with gen_music_ref.ts), so a Dart client and a TS one play the same bar.

import 'dart:convert';
import 'dart:io';

import 'package:agent_office/audio/score.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ref = jsonDecode(File('test/audio/music_ref.json').readAsStringSync()) as Map<String, dynamic>;

  test('hash matches the TS bit for bit', () {
    for (final row in ref['hash'] as List) {
      final [a as int, b as int, v as num] = row as List;
      expect(hash(a, b), v, reason: 'hash($a, $b)');
    }
  });

  test('mulberry matches the TS', () {
    (ref['mulberry'] as Map<String, dynamic>).forEach((seed, values) {
      final r = mulberry(int.parse(seed));
      for (final v in values as List) {
        expect(r(), v);
      }
    });
  });

  test('imul wraps like Math.imul', () {
    expect(imul(0x7fffffff, 2), 0xfffffffe);
    expect(imul(0xffffffff, 0xffffffff), 1);
    expect(imul(-1, 5), 0xfffffffb);
  });

  test('a 32-bar round: keys, then bass, drums, melody, a breakdown', () {
    final want = ref['section'] as List;
    for (var b = 0; b < want.length; b++) {
      final s = section(b);
      final w = want[b] as Map<String, dynamic>;
      expect((s.drums, s.bass, s.melody), (w['drums'], w['bass'], w['melody']), reason: 'bar $b');
    }
  });

  for (final MapEntry(key: id, value: t as Map<String, dynamic>) in (ref['tunes'] as Map<String, dynamic>).entries) {
    group(id, () {
      final score = Score(id);

      test('the step length', () => expect(score.step, closeTo(t['step'] as num, 1e-12)));

      test('the melody', () {
        final want = [
          for (final bar in t['melody'] as List) [for (final n in bar as List) (n[0] as int, n[1] as int, n[2] as int)],
        ];
        expect(score.melody, want);
      });

      test('every note of the round, 16th by 16th', () {
        final want = t['events'] as List;
        final got = <List<num>>[
          for (var k = 0; k < 32 * 16 + 20; k++)
            for (final e in score.eventsAt(k)) [k, e.voice.index, e.delay, e.midi, e.len, e.vel],
        ];
        expect(got.length, want.length);
        for (var i = 0; i < got.length; i++) {
          final w = want[i] as List;
          final g = got[i];
          expect(g.sublist(0, 2), [w[0], w[1]], reason: 'event $i');
          expect(g[3], w[3], reason: 'midi of event $i');
          for (final j in [2, 4, 5]) {
            expect(g[j], closeTo(w[j] as num, 1e-9), reason: 'field $j of event $i');
          }
        }
      });

      test('the beat for the lights', () {
        for (final row in t['beats'] as List) {
          final [at as num, v as num] = row as List;
          expect(score.beat(at.toDouble()), closeTo(v, 1e-12), reason: 'beat($at)');
        }
      });

      test('the clock schedules the same 16ths at the same audio times, and picks up after a jump', () {
        final clock = TuneClock(score);
        final got = <(int, double)>[];
        final want = <(int, double)>[];
        for (final x in t['due'] as List) {
          if (x[0] == 'tick') {
            // A tick is marked (-1, at) in both lists, before what it schedules.
            final at = (x[1] as num).toDouble();
            want.add((-1, at));
            got.add((-1, at));
            got.addAll(clock.due(at, (x[2] as num).toDouble()));
          } else {
            want.add((x[0] as int, (x[1] as num).toDouble()));
          }
        }
        expect(got.length, want.length);
        for (var i = 0; i < got.length; i++) {
          expect(got[i].$1, want[i].$1, reason: 'entry $i');
          expect(got[i].$2, closeTo(want[i].$2, 1e-9), reason: 'entry $i');
        }
      });
    });
  }

  test('the same start time gives the same notes, whoever computes them', () {
    final a = Score('coffee-break'), b = Score('coffee-break');
    for (var k = 0; k < 600; k += 7) {
      expect(a.eventsAt(k).toString(), b.eventsAt(k).toString());
    }
    // An unknown tune falls back to the first one.
    expect(Score('nope').tune, tunes['rainy-window']);
  });
}
