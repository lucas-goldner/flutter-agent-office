// The desktop app's sound against the web's: each case of lib/dev/audio_parity_cases.dart rendered by the
// Dart synth (office_render.dart, music_render.dart) through the same chain the web's OfficeSound.offline
// has (the panner, the master volume easing in, the master compressor), measured like
// dev/audio_parity.py measures Web Audio's renders, whose numbers are in parity_web.json.
//
// To refresh those: build lib/dev/audio_parity.dart and run dev/audio_parity.py (see its header).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_office/audio/dnb_score.dart' show djBar, djStep;
import 'package:agent_office/audio/music_render.dart';
import 'package:agent_office/audio/office_render.dart';
import 'package:agent_office/audio/score.dart';
import 'package:agent_office/audio/sound_model.dart';
import 'package:agent_office/audio/synth.dart';
import 'package:agent_office/dev/audio_parity_cases.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart' show Cabinet;

const int sr = 48000;

typedef Metrics = ({double rms, double lr, double centroid, double peak});

Metrics measure(Float32List l, Float32List r) {
  final mono = Float32List(l.length);
  for (var i = 0; i < l.length; i++) {
    mono[i] = (l[i] + r[i]) / 2;
  }
  final pl = rmsOf(l), pr = rmsOf(r);
  return (
    rms: math.sqrt((pl * pl + pr * pr) / 2),
    lr: pl / math.max(1e-12, pr),
    centroid: spectralCentroid(mono, sr),
    peak: math.max(peakOf(l), peakOf(r)),
  );
}

/// A mono sound, as the web's office plays it once it's settled: placed [at] seconds in, through a
/// panner at [from] (or none), the master volume (0.7, squared), and the master compressor.
Metrics office(String name, Float32List sound, {double at = 0, Pos? from, double ref = 1.5, double rolloff = 1.2}) {
  final (seconds, listener) = parityCases[name]!;
  final n = (seconds * sr).round();
  final l = Float32List(n), r = Float32List(n);
  var gl = 1.0, gr = 1.0, g = 1.0;
  if (from != null) {
    final h = hearAt(listener, from, ref, rolloff);
    g = h.gain;
    gl = h.left;
    gr = h.right;
  }
  final o = (at * sr).round();
  for (var i = 0; i < sound.length && o + i < n; i++) {
    l[o + i] = sound[i] * g * gl;
    r[o + i] = sound[i] * g * gr;
  }
  for (var i = 0; i < n; i++) {
    l[i] *= 0.49;
    r[i] *= 0.49;
  }
  Compressor(threshold: -14, knee: 12, ratio: 4, attack: 0.004, release: 0.25, sr: sr).process(l, r);
  return measure(l, r);
}

Metrics mean(List<Metrics> ms) {
  double avg(double Function(Metrics) f) => ms.map(f).reduce((a, b) => a + b) / ms.length;
  // Powers average, like the web side's.
  return (
    rms: math.sqrt(avg((m) => m.rms * m.rms)),
    lr: avg((m) => m.lr),
    centroid: avg((m) => m.centroid * m.rms * m.rms) / avg((m) => m.rms * m.rms),
    peak: avg((m) => m.peak),
  );
}

/// The Dart side of every case.
Map<String, Metrics> dartSide() {
  final r = OfficeRender(sr, math.Random(7));
  final out = <String, Metrics>{};
  Metrics many(Metrics Function() f) => mean([for (var i = 0; i < 6; i++) f()]);
  out['room'] = office('room', r.roomTone());
  out['ding.done'] = office('ding.done', r.ding(Ding.done));
  out['ding.needsInput'] = office('ding.needsInput', r.ding(Ding.needsInput));
  out['gong.merged'] = many(
    () => office('gong.merged', r.gongStroke(1), at: 0.03, from: gongAt, ref: 8, rolloff: 0.45),
  );
  out['gong.hit'] = many(
    () =>
        office('gong.hit', r.gongStroke(0.6 + 0.2 * r.rng.nextDouble()), at: 0.03, from: gongAt, ref: 4, rolloff: 0.6),
  );
  out['gong.queue'] = many(() => office('gong.queue', r.gongQueue(), at: 0.03, from: gongAt, ref: 8, rolloff: 0.45));
  out['coffee'] = many(() => office('coffee', r.coffee(), at: 0.05, from: coffeeMachine, ref: 1.2, rolloff: 1));
  out['bark3'] = many(() => office('bark3', r.bark(3), at: 0.03, from: parityNear, ref: 2, rolloff: 1));
  out['yip'] = many(() => office('yip', r.yip(), at: 0.02, from: parityNear, ref: 1.5, rolloff: 1));
  out['steps6'] = many(() {
    final mix = Float32List(sr);
    for (var i = 0; i < 6; i++) {
      final s = r.samples.steps[r.rng.nextInt(3)];
      final rate = 0.9 + 0.2 * r.rng.nextDouble();
      mixInto(mix, playBuffer(mix.length, sr, s, rate: rate), k: 0.16 + 0.05 * r.rng.nextDouble());
    }
    return office('steps6', mix);
  });
  out['stepAt'] = many(() {
    final s = playBuffer(sr, sr, r.samples.steps[r.rng.nextInt(3)], rate: 0.9 + 0.2 * r.rng.nextDouble());
    return office(
      'stepAt',
      scale(s, 0.3 + 0.08 * r.rng.nextDouble()),
      from: const Pos(0, 0.1, -2),
      ref: 1.5,
      rolloff: 1.4,
    );
  });
  out['thunder'] = many(() => office('thunder', r.thunder(1, 0.45 * 0.6, true), at: 0.2));
  out['pour'] = many(() => office('pour', r.pour(), at: 0.05, from: const Pos(0, 1, -2), ref: 1.2, rolloff: 1));
  out['hiccup'] = many(() => office('hiccup', r.hiccup(), at: 0.005));
  const cabinet = Pos(Cabinet.x, 1.4, Cabinet.z);
  out['arcade.clear3'] = office('arcade.clear3', r.arcade('clear', 3), at: 0.02, from: cabinet, ref: 1.5, rolloff: 1.2);
  out['arcade.over'] = office('arcade.over', r.arcade('over'), at: 0.02, from: cabinet, ref: 1.5, rolloff: 1.2);
  for (final k in const ['bounce', 'score']) {
    out['ball.$k'] = many(
      () => office('ball.$k', r.ball(k, 5 / 7), at: 0.005, from: const Pos(0, 1, -2), ref: 2, rolloff: 1.1),
    );
  }

  // Bars of music, straight out (no panner, no master).
  final score = Score('rainy-window');
  for (final from in const [0, 8]) {
    final t = TuneRender(sr, 'rainy-window', score.stepTime(from * 16), lastStep: from * 16 + 15);
    final c = t.render(((score.step * 16 + 1) * sr).round());
    out['tune.rainy-window.$from'] = measure(c.left, c.right);
  }
  for (final b in const [0, 24, 64, 88]) {
    final d = DjRender(sr, b * 16 * djStep, lastStep: b * 16 + 15);
    final c = d.render(((djBar + 1) * sr).round());
    out['dj.$b'] = measure(c.left, c.right);
  }
  // The horn 1.3 s into a set (its fade is done by then), the set otherwise silent.
  final horn = renderHorn(sr);
  final n = 3 * sr, at = (1.3 * sr).round();
  final l = Float32List(n), rr = Float32List(n);
  l.setRange(at, math.min(n, at + horn[0].length), horn[0]);
  rr.setRange(at, math.min(n, at + horn[1].length), horn[1]);
  out['dj.horn'] = measure(l, rr);
  return out;
}

void main() {
  final file = File('test/audio/parity_web.json');

  test('every sound sounds like the web version (RMS within 1.5 dB, spectral centroid within 25%)', () {
    final web = (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()))),
    );
    final dart = dartSide();
    final rows = <String>[];
    final off = <String>[];
    for (final name in web.keys) {
      final w = web[name]!, d = dart[name];
      if (d == null) continue;
      final db = 20 * math.log(d.rms / w['rms']!) / math.ln10;
      final cent = d.centroid / w['centroid']!;
      rows.add(
        '${name.padRight(22)} rms ${w['rms']!.toStringAsFixed(4)} → ${d.rms.toStringAsFixed(4)} (${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB)'
        '  centroid ${w['centroid']!.toStringAsFixed(0).padLeft(5)} → ${d.centroid.toStringAsFixed(0).padLeft(5)} Hz'
        '  L/R ${w['lr']!.toStringAsFixed(2)} → ${d.lr.toStringAsFixed(2)}',
      );
      // The DJ's saws and the reese's distortion come out a little brighter than Chromium's.
      final brightness = name.startsWith('dj.') ? 0.3 : 0.25;
      if (db.abs() > 1.5 || (cent - 1).abs() > brightness) off.add(name);
    }
    print(rows.join('\n'));
    expect(off, isEmpty, reason: 'not like the web: $off');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
