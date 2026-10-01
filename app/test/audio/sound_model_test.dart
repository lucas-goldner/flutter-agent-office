import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_office/audio/samples.dart';
import 'package:agent_office/audio/sound_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('where sounds come from', () {
    test('the office windows, not the loft ones (as sound.ts computes them)', () {
      expect(
        [for (final w in soundWindows) (w.x, w.y, w.z)],
        [
          (-14.0, 2.4, 14.5),
          (-9.0, 2.4, 14.5),
          (1.0, 2.4, 14.5),
          (-19.5, 2.4, -9.0),
          (-19.5, 2.4, -3.0),
          (-19.5, 2.4, 3.0),
        ],
      );
    });

    test('the gong and the jukebox', () {
      // Upstream moved the gong past the elevator (GONG.x 3.5 -> 11.8).
      expect([gongAt.x, gongAt.y, gongAt.z], [11.8, closeTo(1.09, 1e-12), -12.25]);
      expect([jukeboxAt.x, jukeboxAt.y, jukeboxAt.z], [closeTo(17.58, 1e-12), 0.75, 5.4]);
    });

    test('office, garage or out in the rain', () {
      expect(whereIs(const Pos(0, 1.4, 0)), Where.office);
      expect(whereIs(const Pos(0, -2, 0)), Where.garage);
      expect(whereIs(const Pos(18.2, -2, 0)), Where.garage);
      expect(whereIs(const Pos(0, -2, 25)), Where.out);
      expect(whereIs(const Pos(-19, 1.4, 6.5)), Where.out);
    });

    test('rain is loudest and brightest out in it', () {
      expect(rainLevel(0.005, Where.out), 0);
      expect(rainLevel(1, Where.office), closeTo(0.06, 1e-12));
      expect(rainLevel(1, Where.garage), closeTo(0.11, 1e-12));
      expect(rainLevel(0.5, Where.out), closeTo(0.16 * math.pow(0.5, 0.8), 1e-12));
      expect([for (final w in Where.values) rainCutoff(w)], [1300, 2600, 6500]);
    });
  });

  group('the jukebox across the room', () {
    test('muffled past 5 m, never below 1600 Hz', () {
      expect(musicCutoffAt(0), 16000);
      expect(musicCutoffAt(4.9), 16000);
      expect(musicCutoffAt(10), closeTo(16000 * math.pow(0.5, 1.5), 1e-9));
      expect(musicCutoffAt(100), 1600);
    });

    test('a stream fades like the inverse-distance panner the tunes go through', () {
      expect(streamVolume(0.25, 0), 0.25);
      expect(streamVolume(0.25, 2.5), 0.25);
      expect(streamVolume(1, 10), closeTo(2.5 / (2.5 + 1.3 * 7.5), 1e-12));
      expect(streamVolume(4, 1), 1);
    });

    test('the same play, resent, is recognised', () {
      const a = JukeboxPlay(track: 'rainy-window', startedAt: 100, since: 5);
      expect(a.samePlayAs(const JukeboxPlay(track: 'rainy-window', startedAt: 100, since: 900)), isTrue);
      expect(a.samePlayAs(const JukeboxPlay(track: 'rainy-window', startedAt: 101, since: 5)), isFalse);
      expect(a.samePlayAs(const JukeboxPlay(track: 'stream', url: 'x', startedAt: 100, since: 5)), isFalse);
    });

    test('dings from worker statuses', () {
      expect(Ding.fromStatus('done'), Ding.done);
      expect(Ding.fromStatus('needs_input'), Ding.needsInput);
      expect(Ding.fromStatus('working'), isNull);
    });
  });

  group('a worker typing', () {
    List<(double, KeyKind)> run(Typist<Object> t, math.Random rng, double from, double to) {
      final keys = <(double, KeyKind)>[];
      for (var now = from; now < to; now += 1 / 60) {
        t.schedule(now, rng, (when, kind) => keys.add((when, kind)));
      }
      return keys;
    }

    test('bursts of keys a word at a time, with spaces, Enter and mouse clicks, never far ahead', () {
      final t = Typist<Object>(1, 2)..on = true;
      final keys = run(t, math.Random(42), 10, 130);
      final kinds = {for (final (_, k) in keys) k};
      expect(kinds, KeyKind.values.toSet());
      expect(keys.length, greaterThan(300));
      for (var i = 1; i < keys.length; i++) {
        expect(keys[i].$1, greaterThanOrEqualTo(keys[i - 1].$1), reason: 'keys in order');
      }
      // Scheduled at most 0.12 s ahead of the last frame (a second mouse click may land 0.16 s after the first).
      expect(keys.last.$1, lessThan(130 + 0.12 + 0.16));
      // Keys within a word are 65–160 ms apart.
      for (var i = 1; i < keys.length; i++) {
        if (keys[i - 1].$2 == KeyKind.key && keys[i].$2 == KeyKind.key) {
          final gap = keys[i].$1 - keys[i - 1].$1;
          expect(gap, anyOf(inInclusiveRange(0.065, 0.16), greaterThanOrEqualTo(0.6)));
        }
      }
    });

    test('starts again shortly after falling behind (a hidden tab)', () {
      final t = Typist<Object>(0, 0)..on = true;
      final rng = math.Random(1);
      run(t, rng, 0, 5);
      final keys = <double>[];
      t.schedule(100, rng, (when, _) => keys.add(when));
      expect(t.next, greaterThanOrEqualTo(100));
      for (final k in keys) {
        expect(k, greaterThanOrEqualTo(100.05));
      }
    });
  });

  group('samples', () {
    test('key clicks, footsteps and paper are normalized to their peaks', () {
      final s = OfficeSamples(8000, math.Random(3));
      double peak(Float32List d) => d.fold(0.0, (m, v) => math.max(m, v.abs()));
      expect(s.keys, hasLength(6));
      expect(s.spaces, hasLength(2));
      expect(s.steps, hasLength(3));
      for (final k in [...s.keys, ...s.spaces, s.mouse, ...s.steps, s.drop]) {
        expect(peak(k), closeTo(0.9, 1e-6));
      }
      expect(peak(s.rustle), closeTo(0.8, 1e-6));
      expect(s.keys.first.length, (8000 * 0.12).ceil());
      expect(s.white.length, 8000 * 5);
      expect(s.brown.length, 8000 * 6);
      // The gurgle is a 0–1 level.
      expect(s.gurgle.every((v) => v >= 0 && v <= 1), isTrue);
    });

    test('a loopable buffer runs smoothly from its end into its start', () {
      var i = 0;
      final d = loopable(1000, 1, () => math.sin(i++ * 0.01));
      // raw[n] would have followed d[n-1]; the crossfade makes d[0] that sample.
      expect(d[0], closeTo(math.sin(1000 * 0.01), 1e-6));
      expect((d[0] - d[d.length - 1]).abs(), lessThan(0.02));
    });

    test('the jukebox samples', () {
      final s = TuneSamples(8000, math.Random(5));
      expect(s.noise.length, 8000 * 3);
      expect(s.crackle.length, 8000 * 5);
      expect(s.room, hasLength(2));
      expect(s.room.first.length, (8000 * 1.6).floor());
    });
  });
}
