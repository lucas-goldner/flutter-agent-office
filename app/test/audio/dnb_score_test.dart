// The DJ's set against the old TypeScript client's dnb.ts: dnb_ref.json is what its trackAt, plan,
// djFrame and scale computed (run with bun from upstream's source), so a Dart client on the roof
// hears, and sees the lights flash on, the same bar as anyone else up there.

import 'dart:convert';
import 'dart:io';

import 'package:agent_office/audio/dnb_score.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ref = jsonDecode(File('test/audio/dnb_ref.json').readAsStringSync()) as Map<String, dynamic>;

  test('each track of the set is the TS one: key, chords, groove, bass, arpeggio, horn and colour', () {
    for (final t in (ref['tracks'] as List).cast<Map<String, dynamic>>()) {
      final n = t['n'] as int;
      final track = trackAt(n);
      expect(track.root, t['root'], reason: 'track $n root');
      expect(track.prog, t['prog'], reason: 'track $n chords');
      expect(track.groove.kick, t['kick'], reason: 'track $n kick');
      expect(track.groove.snare, t['snare'], reason: 'track $n snare');
      expect(track.bass.name, t['bass'], reason: 'track $n bass');
      expect(track.wah, t['wah'], reason: 'track $n wah');
      expect(track.arp, t['arp'], reason: 'track $n arpeggio');
      expect(track.horn, t['horn'], reason: 'track $n horn');
      expect(track.hue, t['hue'], reason: 'track $n hue');
    }
  });

  test('every 16th plays what the TS played', () {
    for (final row in (ref['plans'] as List).cast<List<dynamic>>()) {
      final [k as int, part, bar, second, s, chord, kick, snare, hat, openHat, shaker] = row;
      final p = plan(k);
      final why = '16th $k';
      expect(p.section.part.name, part, reason: why);
      expect(p.section.bar, bar, reason: why);
      expect(p.section.second, second, reason: why);
      expect(p.s, s, reason: why);
      expect(p.chord, chord, reason: why);
      expect(p.kick, closeTo(kick as num, 1e-12), reason: why);
      expect(p.snare, closeTo(snare as num, 1e-12), reason: why);
      expect(p.hat, closeTo(hat as num, 1e-12), reason: why);
      expect(p.openHat, openHat, reason: why);
      expect(p.shaker, closeTo(shaker as num, 1e-12), reason: why);
    }
  });

  test('the lights see the same frame as the TS at any moment', () {
    for (final f in (ref['frames'] as List).cast<Map<String, dynamic>>()) {
      final at = (f['at'] as num).toDouble();
      final d = djFrame(at);
      final why = 'at $at';
      expect(d.beats, closeTo(f['beats'] as num, 1e-9), reason: why);
      expect(d.beat, closeTo(f['beat'] as num, 1e-9), reason: why);
      expect(d.kick, closeTo(f['kick'] as num, 1e-9), reason: why);
      expect(d.snare, closeTo(f['snare'] as num, 1e-9), reason: why);
      expect(d.energy, closeTo(f['energy'] as num, 1e-9), reason: why);
      expect(d.part.name, f['part'], reason: why);
      expect(d.rise, closeTo(f['rise'] as num, 1e-9), reason: why);
      if (f['sinceDrop'] == null) {
        expect(d.sinceDrop, double.infinity, reason: why);
      } else {
        expect(d.sinceDrop, closeTo(f['sinceDrop'] as num, 1e-9), reason: why);
      }
      expect(d.track, f['track'], reason: why);
      expect(d.hue, f['hue'], reason: why);
    }
  });

  test('notes of the minor scale, octaves and all', () {
    for (final row in (ref['scales'] as List).cast<List<dynamic>>()) {
      final [root as int, degree as int, note as int] = row;
      expect(scaleNote(root, degree), note, reason: 'scale($root, $degree)');
    }
  });

  group('the set', () {
    test('is the same every time it is asked (and after asking about another track)', () {
      final a = [for (var k = 0; k < 400; k++) plan(k)];
      trackAt(99);
      final b = [for (var k = 0; k < 400; k++) plan(k)];
      for (var k = 0; k < 400; k++) {
        expect(b[k].kick, a[k].kick);
        expect(b[k].snare, a[k].snare);
        expect(b[k].chord, a[k].chord);
        expect(identical(b[k].track, a[k].track) || b[k].track.hue == a[k].track.hue, isTrue);
      }
    });

    test('runs intro, build, drop, breakdown, build, drop over a track of 96 bars', () {
      final parts = <String>[];
      for (var bar = 0; bar < trackBars; bar++) {
        final p = sectionOf(bar).part.name;
        if (parts.isEmpty || parts.last != p) parts.add(p);
      }
      expect(parts, ['intro', 'build', 'drop', 'breakdown', 'build', 'drop']);
      expect(sectionOf(trackBars - 1).second, isTrue);
      expect(sectionOf(0).second, isFalse);
    });

    test('drops hit hard, a build rises to them, and every frame stays in range', () {
      // Bar 24 of a track is the first drop; bar 16 the first build.
      final drop = djFrame(24 * djBar + 0.001);
      expect(drop.part, Part.drop);
      expect(drop.energy, 1);
      expect(drop.sinceDrop, lessThan(0.01));
      final build = djFrame(20 * djBar);
      expect(build.part, Part.build);
      expect(build.rise, closeTo(0.5, 1e-9));
      for (var at = 0.0; at < 200; at += 0.37) {
        final f = djFrame(at);
        expect(f.beat, inInclusiveRange(0, 1));
        expect(f.kick, inInclusiveRange(0, 1));
        expect(f.snare, inInclusiveRange(0, 1));
        expect(f.energy, inInclusiveRange(0, 1));
        expect(f.hue, inInclusiveRange(0, 1));
      }
    });

    test('keeps time by the office clock, from the start of 2026', () {
      expect(djTime(DateTime.utc(2026).millisecondsSinceEpoch.toDouble()), 0);
      expect(djTime(DateTime.utc(2026, 1, 1, 0, 1).millisecondsSinceEpoch.toDouble()), 60);
    });
  });

  test("the bass's grit is a soft clip from -1 to 1", () {
    final c = driveCurve(2.2);
    expect(c.length, 1024);
    expect(c.first, closeTo(-1, 1e-6));
    expect(c.last, closeTo(1, 1e-6));
    for (var i = 1; i < c.length; i++) {
      expect(c[i], greaterThanOrEqualTo(c[i - 1]));
    }
  });

  test('the DJ booth says what the set is doing', () {
    expect(djDoing(Part.drop), '🔥 the drop');
    expect(djDoing(Part.intro), 'mixing in the next track');
  });
}
