import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_office/audio/office_render.dart';
import 'package:agent_office/audio/sound_model.dart';
import 'package:agent_office/audio/synth.dart';
import 'package:flutter_test/flutter_test.dart';

const int sr = 44100;

/// The frequency of [d] from its rising zero crossings.
double crossingsHz(Float32List d) {
  var first = -1, last = -1, count = 0;
  for (var i = 1; i < d.length; i++) {
    if (d[i - 1] < 0 && d[i] >= 0) {
      if (first < 0) {
        first = i;
      } else {
        count++;
      }
      last = i;
    }
  }
  return count * sr / (last - first);
}

/// RMS of a sine at [hz] through [type] filter at [cutoff].
double through(BiquadType type, double cutoff, double q, double hz) {
  final s = osc(sr, sr, Wave.sine, Param(hz));
  biquad(s, sr, type, cutoff, q);
  return rmsOf(s, sr ~/ 2);
}

void main() {
  group('oscillators', () {
    test('a sine is at its frequency, and starts at phase 0', () {
      final s = osc(sr, sr, Wave.sine, Param(440));
      expect(crossingsHz(s), closeTo(440, 0.5));
      expect(s[0], 0);
      expect(rmsOf(s), closeTo(1 / math.sqrt2, 0.01));
    });

    test('square, sawtooth and triangle keep the pitch, and their levels', () {
      for (final (w, rms) in const [(Wave.square, 1.0), (Wave.sawtooth, 0.577), (Wave.triangle, 0.577)]) {
        final s = osc(sr, sr, w, Param(220));
        expect(crossingsHz(s), closeTo(220, 1), reason: '$w');
        expect(rmsOf(s), closeTo(rms, 0.03), reason: '$w');
      }
    });

    test('detune is in cents, and only plays between start and stop', () {
      final s = osc(sr, sr, Wave.sine, Param(440), detune: Param(1200), start: 0.25, stop: 0.75);
      expect(rmsOf(s, 0, sr ~/ 4 - 1), 0);
      expect(rmsOf(s, (sr * 0.76).ceil()), 0);
      expect(crossingsHz(Float32List.sublistView(s, sr ~/ 4, sr * 3 ~/ 4)), closeTo(880, 2));
    });

    test('an exponential frequency ramp glides up', () {
      final f = Param(200)
        ..setValueAtTime(200, 0)
        ..exponentialRampToValueAtTime(800, 1);
      final s = osc(sr, sr, Wave.sine, f);
      final early = crossingsHz(Float32List.sublistView(s, 0, sr ~/ 10));
      final late = crossingsHz(Float32List.sublistView(s, sr * 9 ~/ 10));
      expect(early, closeTo(214, 12));
      expect(late, closeTo(750, 40));
    });
  });

  group('envelopes (AudioParam automation)', () {
    test('linear and exponential ramps, like Web Audio', () {
      final p = Param(1)
        ..setValueAtTime(0.0001, 0)
        ..exponentialRampToValueAtTime(1, 0.1)
        ..exponentialRampToValueAtTime(0.0001, 1);
      expect(p.valueAt(0), closeTo(0.0001, 1e-9));
      expect(p.valueAt(0.05), closeTo(0.01, 1e-4)); // halfway in log: 1e-2
      expect(p.valueAt(0.1), closeTo(1, 1e-9));
      expect(p.valueAt(0.55), closeTo(0.01, 1e-4));
      expect(p.valueAt(2), closeTo(0.0001, 1e-9));
      final e = Param(0)..envelope(0.5, const [(0.1, 1), (0.5, 0.5), (1, 0)]);
      expect(e.valueAt(0.2), 0);
      expect(e.valueAt(0.55), closeTo(0.5, 1e-9));
      expect(e.valueAt(0.8), closeTo(0.75, 1e-9));
      expect(e.valueAt(1.25), closeTo(0.25, 1e-9));
      expect(e.valueAt(3), 0);
    });

    test('setTargetAtTime eases towards its target with its time constant', () {
      final p = Param(0)
        ..setValueAtTime(1, 0)
        ..setTargetAtTime(0, 1, 0.5);
      expect(p.valueAt(0.5), 1);
      expect(p.valueAt(1.5), closeTo(math.exp(-1), 1e-9));
      expect(p.valueAt(3.5), closeTo(math.exp(-5), 1e-9));
    });

    test('the value before any event, and rendering a stretch', () {
      final p = Param(0.3);
      expect(p.render(4, sr), everyElement(closeTo(0.3, 1e-7)));
      p.setValueAtTime(1, 0.5);
      final r = p.render(sr, sr);
      expect(r[sr ~/ 4], closeTo(0.3, 1e-7));
      expect(r[sr * 3 ~/ 4], 1);
    });
  });

  group('filters', () {
    test('a lowpass passes the lows and cuts the highs (12 dB an octave)', () {
      final low = through(BiquadType.lowpass, 1000, 0, 100);
      final high = through(BiquadType.lowpass, 1000, 0, 8000);
      expect(low, closeTo(0.707, 0.01));
      expect(20 * math.log(high / 0.707) / math.ln10, closeTo(-36, 3));
    });

    test('Q is in dB for a lowpass: 0 dB is a gain of 1 at the cutoff, 6 dB of 2', () {
      expect(through(BiquadType.lowpass, 1000, 0, 1000), closeTo(0.707, 0.02));
      expect(through(BiquadType.lowpass, 1000, 6, 1000), closeTo(0.707 * 2, 0.05));
    });

    test('a highpass, and a bandpass that peaks at 0 dB', () {
      expect(through(BiquadType.highpass, 1000, 0, 100), lessThan(0.01));
      expect(through(BiquadType.highpass, 1000, 0, 8000), closeTo(0.707, 0.01));
      expect(through(BiquadType.bandpass, 1000, 2, 1000), closeTo(0.707, 0.01));
      expect(through(BiquadType.bandpass, 1000, 2, 4000), lessThan(0.707 / 4));
    });
  });

  group('effects', () {
    test('a feedback echo repeats, quieter each time', () {
      final e = FeedbackEcho(0.1, sr, 0.5, 1);
      final x = Float32List(sr);
      x[0] = 1;
      final w = e.wet(x);
      expect(w[(0.1 * sr).round()], closeTo(1, 1e-6));
      expect(w[(0.2 * sr).round()], closeTo(0.5, 1e-6));
      expect(w[(0.3 * sr).round()], closeTo(0.25, 1e-6));
    });

    test('the convolver matches direct convolution (Chromium-normalized), in any chunking', () {
      final rng = math.Random(3);
      final ir = [
        Float32List.fromList([for (var i = 0; i < 3000; i++) (rng.nextDouble() * 2 - 1) * math.exp(-i / 600)]),
      ];
      final x = Float32List.fromList([for (var i = 0; i < 5000; i++) rng.nextDouble() * 2 - 1]);
      final c = Convolver(ir, sr, block: 256);
      final out = <double>[];
      for (var at = 0; at < x.length; at += 700) {
        out.addAll(c.process(Float32List.sublistView(x, at, math.min(x.length, at + 700)))[0]);
      }
      var power = 0.0;
      for (final v in ir[0]) {
        power += v * v;
      }
      final scale = 1 / math.sqrt(power / ir[0].length) * math.pow(10, -58 / 20);
      for (final i in [300, 1000, 2999, 4500]) {
        var direct = 0.0;
        for (var j = 0; j <= i && j < ir[0].length; j++) {
          direct += x[i - j] * ir[0][j];
        }
        // The convolver runs a block late.
        expect(out[i + 256], closeTo(direct * scale, 1e-4), reason: 'sample $i');
      }
    });

    test("the compressor's knee and makeup gain, like Chromium's", () {
      final c = Compressor(threshold: -14, knee: 12, ratio: 4, sr: sr);
      expect(c.gainFor(0.01), 1);
      expect(c.makeup, greaterThan(1.2));
      expect(c.makeup, lessThan(2));
      // Loud input is turned down hard.
      expect(c.gainFor(1), lessThan(0.7));
    });

    test('a float WAV in memory', () {
      final w = wav(Float32List.fromList([0, 0.5, -1]), sr);
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(w.length, 44 + 12);
      expect(ByteData.sublistView(w).getFloat32(48, Endian.little), 0.5);
    });
  });

  group('the office, rendered', () {
    final r = OfficeRender(sr, math.Random(1));

    void sensible(String name, Float32List d, {required double minRms, required double maxPeak}) {
      final rms = rmsOf(d), peak = peakOf(d);
      expect(rms, greaterThan(minRms), reason: '$name RMS $rms');
      expect(peak, lessThan(maxPeak), reason: '$name peak $peak');
      expect(d.every((v) => v.isFinite), isTrue, reason: name);
    }

    test('every one-shot makes a sound, none of them clipping', () {
      sensible('gong hit', r.gongStroke(0.7), minRms: 0.005, maxPeak: 0.9);
      sensible('gong merged', r.gongStroke(1), minRms: 0.005, maxPeak: 0.9);
      sensible('gong queue', r.gongQueue(), minRms: 0.005, maxPeak: 1);
      sensible('ding done', r.ding(Ding.done), minRms: 0.02, maxPeak: 0.4);
      sensible('ding needs input', r.ding(Ding.needsInput), minRms: 0.02, maxPeak: 0.4);
      sensible('coffee', r.coffee(), minRms: 0.005, maxPeak: 0.5);
      sensible('bark', r.bark(3), minRms: 0.01, maxPeak: 1);
      sensible('yip', r.yip(), minRms: 0.01, maxPeak: 1);
      for (final k in ['land', 'clear', 'over']) {
        sensible('arcade $k', r.arcade(k, 3), minRms: 0.005, maxPeak: 0.3);
      }
      for (final k in ['bounce', 'rim', 'board', 'score']) {
        sensible('ball $k', r.ball(k, 0.8), minRms: 0.002, maxPeak: 1);
      }
      sensible('birds', r.birds(), minRms: 0.002, maxPeak: 0.2);
      sensible('crickets', r.crickets(), minRms: 0.0005, maxPeak: 0.1);
      sensible('phone', r.phone(2), minRms: 0.005, maxPeak: 0.1);
      sensible('creak', r.creak(), minRms: 0.001, maxPeak: 0.2);
      sensible('thunder', r.thunder(1, 0.45, true), minRms: 0.02, maxPeak: 1);
      sensible('pour', r.pour(), minRms: 0.002, maxPeak: 0.3);
      sensible('hiccup', r.hiccup(), minRms: 0.005, maxPeak: 0.3);
    });

    test('the gong rings at its fundamental, and a merge outlasts a hit', () {
      final hit = r.gongStroke(0.6), merged = r.gongStroke(1);
      expect(merged.length, greaterThan(hit.length));
      // Its lowest partial is ~118 Hz: most of the sound is well under 1 kHz.
      expect(spectralCentroid(merged, sr), inInclusiveRange(150, 900));
      // Still ringing after 3 s.
      expect(rmsOf(merged, 3 * sr, 4 * sr), greaterThan(0.001));
    });

    test('the dings are the notes they should be', () {
      final d = r.ding(Ding.done);
      expect(crossingsHz(Float32List.sublistView(d, (0.03 * sr).round(), (0.1 * sr).round())), closeTo(660, 25));
      expect(crossingsHz(Float32List.sublistView(d, (0.16 * sr).round(), (0.3 * sr).round())), closeTo(880, 25));
    });

    test('the loops: the room, the fridge, the roof, the rain, typing', () {
      sensible('room tone', r.roomTone(), minRms: 0.002, maxPeak: 0.3);
      sensible('fridge', r.fridgeHum(), minRms: 0.05, maxPeak: 2);
      sensible('roof', r.roof(), minRms: 0.002, maxPeak: 0.4);
      final dull = r.rainHiss(1300), bright = r.rainHiss(6500);
      sensible('rain', dull, minRms: 0.05, maxPeak: 1.5);
      expect(spectralCentroid(bright, sr), greaterThan(spectralCentroid(dull, sr) * 1.5));
      final typing = r.typing(20);
      sensible('typing', typing, minRms: 0.005, maxPeak: 1);
      expect(typing.length, 20 * sr);
    });

    test('a loop runs smoothly into its own start', () {
      final room = r.roomTone();
      final jump = (room.first - room.last).abs();
      expect(jump, lessThan(0.05));
      // The room loops on the air vents' swell (0.06 Hz).
      expect(room.length / sr, closeTo(1 / 0.06, 0.01));
    });
  });
}
