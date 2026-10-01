// The office's sounds rendered to PCM: each of sound_web.dart's Web Audio graphs ported to the offline
// synth (synth.dart), for the desktop app, which plays them through SoLoud (sound_native.dart).
//
// Every render is mono and dry: what goes into the graph's panner in sound_web.dart. Where the sound
// comes from, how loud the room is and the master volume are applied as it plays. Times start at 0
// (the web version starts a few ms after "now"; here the sound starts when it's played).
//
// Pure Dart, so it runs (and is tested) on the VM, and in a background isolate in the app.

import 'dart:math' as math;
import 'dart:typed_data';

import 'samples.dart';
import 'sound_model.dart';
import 'synth.dart';

/// Renders the office's sounds at [sr], with its own samples (key clicks, steps, noise…).
class OfficeRender {
  OfficeRender(this.sr, [math.Random? random])
    : rng = random ?? math.Random(),
      samples = OfficeSamples(sr, random ?? math.Random());

  final int sr;
  final math.Random rng;
  final OfficeSamples samples;

  double _rand(double a, double b) => a + rng.nextDouble() * (b - a);
  int _randInt(int a, int b) => _rand(a.toDouble(), b + 1.0).floor();
  T _pick<T>(List<T> xs) => xs[(rng.nextDouble() * xs.length).floor()];

  Float32List _buf(double seconds) => Float32List(_n(seconds));
  int _n(double seconds) => sampleCount(seconds, sr);
  int _at(double t) => (t * sr).round();

  Float32List _osc(int n, Wave type, Param freq, {double start = 0, double? stop, Param? detune}) =>
      osc(n, sr, type, freq, start: start, stop: stop, detune: detune);

  Float32List _white(int n, {double start = 0, double? stop}) => noise(n, sr, rng, start: start, stop: stop);

  /// A non-looping sample source, played from [start] at [rate] (in a buffer [n] long).
  Float32List _sample(
    int n,
    Float32List s, {
    double start = 0,
    double rate = 1,
    double offset = 0,
    bool loop = false,
    double? stop,
  }) => playBuffer(n, sr, s, start: start, rate: rate, offset: offset, loop: loop, stop: stop);

  // ---- The gong -------------------------------------------------------------------------------------

  /// One stroke of the mallet: a felt thump, the metal ringing, and a bright wash that blooms after.
  /// Added into [out] at [t0].
  void _strike(Float32List out, double t0, double strength) {
    final n = out.length;
    final f0 = 118 * _rand(0.98, 1.02);
    final ringLevel = 0.3 * strength;
    final long = 0.6 + 0.4 * strength;
    final at = _at(t0);
    for (final (ratio, amp, decay) in gongPartials) {
      final f = f0 * ratio;
      final end = decay * long;
      // Each partial only as long as it rings, added in at t0.
      final m = math.min(n - at, _n(end + 0.05));
      for (final cents in const [-1, 1]) {
        final freq = Param(f)
          ..setValueAtTime(f * (1 + 0.012 * strength), 0)
          ..exponentialRampToValueAtTime(f, 1.2);
        final o = _osc(m, Wave.sine, freq, detune: Param(cents * _rand(2, 5)));
        final g = Param(1)
          ..setValueAtTime(0.0001, 0)
          ..exponentialRampToValueAtTime(amp * 0.5, 0.01 + ratio * 0.004)
          ..exponentialRampToValueAtTime(0.0001, end);
        mixInto(out, gain(o, sr, g), at: at, k: ringLevel);
      }
    }
    final thump = biquad(_white(n, start: t0, stop: t0 + 0.15), sr, BiquadType.lowpass, 420, 0.8);
    final thumpG = Param(1)
      ..setValueAtTime(0.0001, t0)
      ..exponentialRampToValueAtTime(0.45 * strength, t0 + 0.005)
      ..exponentialRampToValueAtTime(0.0001, t0 + 0.12);
    mixInto(out, gain(thump, sr, thumpG));
    final washEnd = t0 + 3.5 * long;
    final wash = biquad(_white(n, start: t0, stop: washEnd + 0.05), sr, BiquadType.bandpass, 3200, 1.2);
    final washG = Param(1)
      ..setValueAtTime(0, t0)
      ..linearRampToValueAtTime(0.03 * strength, t0 + 0.45)
      ..exponentialRampToValueAtTime(0.0001, washEnd);
    mixInto(out, gain(wash, sr, washG));
  }

  /// One stroke of [strength] (a hit is 0.6–0.8, a merge 1).
  Float32List gongStroke(double strength) {
    final out = _buf(7 * (0.6 + 0.4 * strength) + 0.1);
    _strike(out, 0, strength);
    return out;
  }

  /// Three strokes, each bigger than the last: the task queue emptied.
  Float32List gongQueue() {
    const strengths = [0.7, 0.85, 1.1];
    final out = _buf(2 * 0.85 + 7 * (0.6 + 0.4 * 1.1) + 0.1);
    for (var i = 0; i < strengths.length; i++) {
      _strike(out, i * 0.85, strengths[i]);
    }
    return out;
  }

  // ---- Alerts --------------------------------------------------------------------------------------

  /// Two notes up when a worker is done, a three-note nudge when it needs input.
  Float32List ding(Ding kind) {
    final notes = kind == Ding.done ? const [660.0, 880.0] : const [880.0, 660.0, 880.0];
    final out = _buf(notes.length * 0.12 + 0.3);
    for (var i = 0; i < notes.length; i++) {
      final t0 = i * 0.12;
      final o = _osc(out.length, Wave.triangle, Param(notes[i]), start: t0, stop: t0 + 0.3);
      final g = Param(1)
        ..setValueAtTime(0.0001, t0)
        ..exponentialRampToValueAtTime(0.3, t0 + 0.02)
        ..exponentialRampToValueAtTime(0.0001, t0 + 0.25);
      mixInto(out, gain(o, sr, g));
    }
    return out;
  }

  // ---- Blips, chips, clinks ------------------------------------------------------------------------

  /// A short pitched blip: a bubble when [ratio] > 1, a drip when < 1. Added into [out].
  void _blip(
    Float32List out,
    double when,
    double freq,
    double ratio,
    double len,
    double level, [
    Wave type = Wave.sine,
  ]) {
    final f = Param(freq)
      ..setValueAtTime(freq, when)
      ..exponentialRampToValueAtTime(freq * ratio, when + len);
    final o = _osc(out.length, type, f, start: when, stop: when + len + 0.02);
    final g = Param(1)
      ..setValueAtTime(0.0001, when)
      ..exponentialRampToValueAtTime(level, when + 0.006)
      ..exponentialRampToValueAtTime(0.0001, when + len);
    mixInto(out, gain(o, sr, g));
  }

  /// A glass rings: a couple of high partials, gone in a moment.
  void _clink(Float32List out, double when, double f, double level) {
    for (final (mul, lvl) in const [(1.0, 1.0), (2.76, 0.4)]) {
      final o = _osc(out.length, Wave.sine, Param(f * mul), start: when, stop: when + 0.3);
      final g = Param(1)
        ..setValueAtTime(0.0001, when)
        ..exponentialRampToValueAtTime(level * lvl, when + 0.003)
        ..exponentialRampToValueAtTime(0.0001, when + 0.25);
      mixInto(out, gain(o, sr, g));
    }
  }

  /// The arcade cabinet: a piece landing ('land'), lines clearing ('clear'), the game ending ('over').
  Float32List arcade(String kind, [int lines = 1]) {
    final out = _buf(kind == 'over' ? 0.8 : 0.5);
    if (kind == 'land') {
      _blip(out, 0, 160, 0.55, 0.07, 0.1, Wave.square);
    } else if (kind == 'clear') {
      const notes = [523, 659, 784, 1047, 1319];
      for (var i = 0; i < notes.length && i <= lines; i++) {
        _blip(out, i * 0.07, notes[i].toDouble(), 1.02, 0.1, 0.09, Wave.square);
      }
    } else {
      const notes = [392, 330, 262, 196];
      for (var i = 0; i < notes.length; i++) {
        _blip(out, i * 0.18, notes[i].toDouble(), 0.97, 0.17, 0.14, Wave.triangle);
      }
    }
    return out;
  }

  /// The basketball: 'bounce', 'rim', 'board' or 'score', [loud] 0–1 (speed / 7).
  Float32List ball(String kind, double loud) {
    final out = _buf(0.6);
    if (kind == 'bounce') {
      _blip(out, 0, _rand(150, 175), 0.7, 0.16, 0.05 + 0.3 * loud);
      mixInto(out, _sample(out.length, _pick(samples.steps), rate: _rand(1.25, 1.4)), k: 0.15 + 0.5 * loud);
    } else if (kind == 'rim') {
      final f = _rand(520, 600);
      for (final (ratio, amp, len) in const [(1.0, 0.1, 0.5), (2.43, 0.06, 0.35), (4.1, 0.03, 0.2)]) {
        _blip(out, 0, f * ratio, 0.99, len, amp * (0.3 + loud));
      }
      mixInto(out, _sample(out.length, _pick(samples.steps), rate: 1.9), k: 0.2 * loud);
    } else if (kind == 'board') {
      mixInto(out, _sample(out.length, _pick(samples.steps), rate: 0.8), k: 0.25 + 0.5 * loud);
      _blip(out, 0, 240, 0.8, 0.12, 0.05 + 0.1 * loud);
    } else {
      final f = Param(2400)
        ..setValueAtTime(1800, 0)
        ..linearRampToValueAtTime(4200, 0.28);
      final n = biquadAuto(_white(out.length, stop: 0.4), sr, BiquadType.bandpass, f, 1.2);
      mixInto(out, gain(n, sr, Param(1)..envelope(0, const [(0.03, 0.22), (0.18, 0.14), (0.34, 0)])));
    }
    return out;
  }

  // ---- The coffee machine ----------------------------------------------------------------------------

  /// Grind, gurgle and drip.
  Float32List coffee() {
    final out = _buf(1.8 + 4.9);
    final n = out.length;
    const t0 = 0.0;
    // Grinder: a buzzing motor with beans crunching in it.
    final mf = Param(70)
      ..setValueAtTime(70, t0)
      ..linearRampToValueAtTime(118, t0 + 0.25)
      ..setValueAtTime(118, t0 + 1.2)
      ..linearRampToValueAtTime(60, t0 + 1.5);
    final motor = biquad(_osc(n, Wave.sawtooth, mf, start: t0, stop: t0 + 1.6), sr, BiquadType.lowpass, 1100, 0.8);
    final crunch = biquad(_white(n, start: t0, stop: t0 + 1.6), sr, BiquadType.bandpass, 2600, 1.2);
    // The rattle (the lumpy signal, 3× fast) adds to the crunch's gain of 0.5.
    final rattle = _sample(n, samples.gurgle, start: t0, stop: t0 + 1.6, rate: 3, loop: true);
    for (var i = 0; i < n; i++) {
      final r = i < _at(t0 + 1.6) ? rattle[i] : 0.0;
      motor[i] += crunch[i] * (0.5 + r);
    }
    gain(motor, sr, Param(1)..envelope(t0, const [(0.08, 0.13), (1.25, 0.13), (1.5, 0)]));
    mixInto(out, motor);

    // Brewing: a hissing, gurgling pour with bubbles popping.
    const t1 = t0 + 1.8;
    final pour = biquad(_white(n, start: t1, stop: t1 + 3.2), sr, BiquadType.bandpass, 850, 0.9);
    final wobble = _sample(n, samples.gurgle, start: t1, stop: t1 + 3.2, loop: true);
    for (var i = 0; i < n; i++) {
      pour[i] *= 0.25 + wobble[i];
    }
    gain(pour, sr, Param(1)..envelope(t1, const [(0.2, 0.3), (2.4, 0.26), (3, 0)]));
    mixInto(out, pour);
    for (var i = 0; i < 14; i++) {
      _blip(out, t1 + _rand(0.2, 2.6), _rand(350, 800), _rand(1.6, 2.4), 0.05, 0.1);
    }
    // The last few drips into the cup.
    for (final dt in const [3.3, 3.9, 4.7]) {
      _blip(out, t1 + dt + _rand(-0.1, 0.1), _rand(1100, 1400), 0.55, 0.05, 0.11);
    }
    return out;
  }

  // ---- The dog -------------------------------------------------------------------------------------

  /// One bark: a buzzy voice that leaps up in pitch and falls away, shaped into a "wuh", with a rasp.
  void _woof(Float32List out, double t, double f, double len, double level) {
    final n = out.length;
    final vf = Param(f)
      ..setValueAtTime(f * 0.75, t)
      ..exponentialRampToValueAtTime(f * 1.45, t + len * 0.22)
      ..exponentialRampToValueAtTime(f * 0.6, t + len);
    final mouthF = Param(950)
      ..setValueAtTime(700, t)
      ..linearRampToValueAtTime(1300, t + len * 0.3)
      ..linearRampToValueAtTime(600, t + len);
    final voice = biquadAuto(
      _osc(n, Wave.sawtooth, vf, start: t, stop: t + len + 0.02),
      sr,
      BiquadType.bandpass,
      mouthF,
      1.1,
    );
    final breath = biquad(_white(n, start: t, stop: t + len + 0.02), sr, BiquadType.bandpass, 1800, 0.8);
    mixInto(voice, breath, k: 0.35);
    final g = Param(1)
      ..setValueAtTime(0.0001, t)
      ..exponentialRampToValueAtTime(level, t + 0.012)
      ..exponentialRampToValueAtTime(level * 0.45, t + len * 0.5)
      ..exponentialRampToValueAtTime(0.0001, t + len);
    mixInto(out, gain(voice, sr, g));
  }

  /// [times] gruff woofs, a third of a second or so apart.
  Float32List bark(int times) {
    final out = _buf(times * 0.42 + 0.3);
    var t = 0.0;
    final pitch = _rand(0.95, 1.05);
    for (var i = 0; i < times; i++) {
      _woof(out, t, 300 * pitch * _rand(0.95, 1.05), 0.17, 0.55);
      t += _rand(0.3, 0.42);
    }
    return out;
  }

  /// A short, high, happy yip.
  Float32List yip() {
    final out = _buf(0.2);
    _woof(out, 0, 620, 0.09, 0.3);
    return out;
  }

  // ---- Around the room -------------------------------------------------------------------------------

  /// A few chirps, heard through the glass.
  Float32List birds() {
    final notes = _randInt(2, 6);
    final out = _buf(0.05 + notes * 0.36 + 0.1);
    final base = _rand(2400, 4200);
    final shape = rng.nextDouble();
    var t = 0.05;
    for (var i = notes; i > 0; i--) {
      final len = _rand(0.06, 0.14);
      final f = Param(base)..setValueAtTime(base * _rand(0.9, 1.05), t);
      if (shape < 0.5) {
        f
          ..exponentialRampToValueAtTime(base * _rand(1.25, 1.6), t + len * 0.6)
          ..exponentialRampToValueAtTime(base * _rand(0.8, 1), t + len);
      } else {
        f.exponentialRampToValueAtTime(base * _rand(0.6, 0.75), t + len);
      }
      final o = _osc(out.length, Wave.sine, f, start: t, stop: t + len + 0.02);
      final g = Param(1)
        ..setValueAtTime(0.0001, t)
        ..exponentialRampToValueAtTime(0.06, t + 0.012)
        ..exponentialRampToValueAtTime(0.0001, t + len);
      mixInto(out, gain(o, sr, g));
      t += len + _rand(0.04, 0.2);
    }
    return biquad(out, sr, BiquadType.lowpass, 5000, 0.7);
  }

  /// A cricket chirping away for a few seconds.
  Float32List crickets() {
    final chirps = _randInt(4, 9);
    final out = _buf(0.05 + chirps * (0.105 + 0.6) + 0.1);
    final freq = _rand(4200, 5200);
    var t = 0.05;
    for (var c = chirps; c > 0; c--) {
      for (var p = 0; p < 3; p++) {
        final o = _osc(out.length, Wave.sine, Param(freq), start: t, stop: t + 0.03);
        final g = Param(1)
          ..setValueAtTime(0.0001, t)
          ..exponentialRampToValueAtTime(0.022, t + 0.004)
          ..exponentialRampToValueAtTime(0.0001, t + 0.022);
        mixInto(out, gain(o, sr, g));
        t += 0.035;
      }
      t += _rand(0.35, 0.6);
    }
    return biquad(out, sr, BiquadType.lowpass, 6000, 0.7);
  }

  /// A desk phone rings [rings] times, through the room.
  Float32List phone(int rings) {
    final out = _buf(0.05 + (rings - 1) * 2.4 + 1.1);
    for (var r = 0; r < rings; r++) {
      final t = 0.05 + r * 2.4;
      final f = Param(1150);
      // A warbling trill, flipping between two notes.
      for (var k = 0; k < 18; k++) {
        f.setValueAtTime(k.isOdd ? 1450 : 1150, t + k / 18);
      }
      final o = _osc(out.length, Wave.triangle, f, start: t, stop: t + 1.05);
      mixInto(out, gain(o, sr, Param(1)..envelope(t, const [(0.02, 0.045), (0.95, 0.045), (1, 0)])));
    }
    return biquad(out, sr, BiquadType.lowpass, 3000, 0.7);
  }

  /// Someone leans back in a creaky chair.
  Float32List creak() {
    final len = _rand(0.25, 0.45);
    final out = _buf(len + 0.05);
    final f0 = _rand(150, 200);
    final f = Param(f0)
      ..setValueAtTime(f0, 0)
      ..linearRampToValueAtTime(f0 * _rand(1.2, 1.5), len);
    final o = biquad(
      _osc(out.length, Wave.sawtooth, f, stop: len + 0.02),
      sr,
      BiquadType.bandpass,
      _rand(900, 1300),
      7,
    );
    return mixInto(out, gain(o, sr, Param(1)..envelope(0, [(0.05, 0.05), (len - 0.05, 0.04), (len, 0)])));
  }

  /// Thunder: a long low rumble [loud] 0–1 (peaking at [peak]), with a crack first when it's close.
  Float32List thunder(double loud, double peak, bool crack) {
    final out = _buf(7);
    final n = out.length;
    final tone = Param(700)
      ..setValueAtTime(700, 0)
      ..exponentialRampToValueAtTime(110, 3.5);
    final src = biquadAuto(
      _sample(n, samples.brown, offset: _rand(0, 5), loop: true, stop: 7),
      sr,
      BiquadType.lowpass,
      tone,
      0.7,
    );
    final g = Param(1)
      ..setValueAtTime(0.0001, 0)
      ..exponentialRampToValueAtTime(peak, 0.08 + (1 - loud) * 0.5)
      ..exponentialRampToValueAtTime(peak * 0.35, 1.3)
      ..exponentialRampToValueAtTime(peak * 0.6, 1.9)
      ..exponentialRampToValueAtTime(0.0001, 4 + loud * 2.5);
    mixInto(out, gain(src, sr, g));
    if (crack) {
      final c = biquad(_white(n, stop: 0.3), sr, BiquadType.bandpass, 1800, 0.6);
      mixInto(out, gain(c, sr, Param(1)..envelope(0, [(0.01, peak * 0.5), (0.25, 0)])));
    }
    return out;
  }

  /// A drink poured at the bar: ice into the glass, a splash, and a clink.
  Float32List pour() {
    final out = _buf(1.8);
    final n = out.length;
    const t0 = 0.0;
    for (var i = 0; i < 3; i++) {
      _clink(out, t0 + i * _rand(0.07, 0.12), _rand(2200, 3200), 0.05);
    }
    final f = Param(700)
      ..setValueAtTime(700, t0 + 0.35)
      ..linearRampToValueAtTime(1500, t0 + 1.15);
    final p = biquadAuto(_white(n, start: t0 + 0.35, stop: t0 + 1.3), sr, BiquadType.bandpass, f, 1.4);
    final wobble = _sample(n, samples.gurgle, start: t0 + 0.35, stop: t0 + 1.3, rate: 4, loop: true);
    for (var i = 0; i < n; i++) {
      p[i] *= 0.6 + wobble[i];
    }
    mixInto(out, gain(p, sr, Param(1)..envelope(t0 + 0.35, const [(0.06, 0.09), (0.7, 0.08), (0.85, 0)])));
    _clink(out, t0 + 1.45, 3900, 0.08);
    return out;
  }

  /// Hic! (The catch in the throat starts 15 ms before the hic.)
  Float32List hiccup() {
    final out = _buf(0.2);
    final n = out.length;
    const t0 = 0.015;
    final f = Param(260)
      ..setValueAtTime(260, t0)
      ..exponentialRampToValueAtTime(420, t0 + 0.06);
    final o = biquad(_osc(n, Wave.sawtooth, f, start: t0, stop: t0 + 0.14), sr, BiquadType.bandpass, 1100, 2.5);
    mixInto(out, gain(o, sr, Param(1)..envelope(t0, const [(0.008, 0.12), (0.05, 0.08), (0.11, 0)])));
    final c = biquad(_white(n, start: 0, stop: t0 + 0.02), sr, BiquadType.bandpass, 1800, 1);
    mixInto(out, gain(c, sr, Param(1)..envelope(0, const [(0.004, 0.08), (0.02, 0)])));
    return out;
  }

  // ---- Loops: the room, the fridge, the roof, the rain, typing ---------------------------------------

  /// A seamless loop of [seconds]: renders a little more and crossfades the end into the start.
  Float32List _loop(int n, Float32List Function(int n) render) {
    final fade = _n(0.25);
    final raw = render(n + fade);
    final d = Float32List.fromList(raw.sublist(0, n));
    for (var i = 0; i < fade; i++) {
      final k = i / fade;
      d[i] = raw[i] * math.sqrt(k) + raw[n + i] * math.sqrt(1 - k);
    }
    return d;
  }

  /// Samples in one period of an LFO near [hz], and the LFO's exact rate for that.
  (int, double) _period(double hz) {
    final n = (sr / hz).round();
    return (n, sr / n);
  }

  /// The room inside: a low rumble of building and traffic, and the air vents swelling slowly.
  Float32List roomTone() {
    final (n, hz) = _period(0.06);
    return _loop(n, (m) {
      final pre = _n(0.5);
      final rumble = biquad(_sample(m + pre, samples.brown, loop: true), sr, BiquadType.lowpass, 300, 0.7);
      final air = biquad(_white(m + pre), sr, BiquadType.bandpass, 650, 0.5);
      final out = Float32List(m);
      for (var i = 0; i < m; i++) {
        final swell = math.sin(2 * math.pi * hz * i / sr);
        out[i] = rumble[i + pre] * 0.07 + air[i + pre] * (0.009 + 0.004 * swell);
      }
      return out;
    });
  }

  /// The fridge's compressor running (1 s, loops exactly): a 50 Hz buzz and a whine, through a lowpass.
  Float32List fridgeHum() {
    final m = sr * 3;
    final hum = _osc(m, Wave.sawtooth, Param(50));
    final whine = _osc(m, Wave.sine, Param(120));
    mixInto(hum, whine, k: 0.3);
    biquad(hum, sr, BiquadType.lowpass, 220, 0.7);
    return Float32List.fromList(hum.sublist(2 * sr));
  }

  /// Up on the roof: traffic far below, and the wind gusting and dropping, whistling higher as it picks up.
  Float32List roof() {
    final (n, hz) = _period(0.08);
    return _loop(n, (m) {
      final pre = _n(0.5);
      final city = biquad(_sample(m + pre, samples.brown, loop: true, offset: 2), sr, BiquadType.lowpass, 420, 0.6);
      final gust = Float32List(m + pre);
      for (var i = 0; i < gust.length; i++) {
        gust[i] = math.sin(2 * math.pi * hz * (i - pre) / sr);
      }
      final f = Param(520);
      final white = _white(m + pre);
      // The wind's bandpass follows the gust (520 ± 220 Hz): coefficients every 16 samples.
      final bq = Biquad(BiquadType.bandpass, f, 0.8);
      const block = 64;
      for (var at = 0; at < white.length; at += block) {
        f.value = 520 + 220 * gust[at];
        final end = math.min(white.length, at + block);
        final part = Float32List.sublistView(white, at, end);
        bq.process(part, sr);
      }
      final out = Float32List(m);
      for (var i = 0; i < m; i++) {
        out[i] = city[i + pre] * 0.08 + white[i + pre] * (0.012 + 0.009 * gust[i + pre]);
      }
      return out;
    });
  }

  /// Rain's hiss (4 s, loops) with its brightness at [cutoff]: 1300 Hz behind glass, 2600 in the garage,
  /// 6500 out in it.
  Float32List rainHiss(double cutoff) => _loop(_n(4), (m) {
    final pre = _n(0.3);
    final w = biquad(_white(m + pre), sr, BiquadType.highpass, 450, 0.5);
    biquad(w, sr, BiquadType.lowpass, cutoff, 0.5);
    return Float32List.fromList(w.sublist(pre));
  });

  /// A worker typing: [seconds] of bursts, words, Enters, clicks and pauses, as sound_model.dart's
  /// Typist plays them, looping. Keys that run past the end wrap round to the start.
  Float32List typing(double seconds) {
    final out = _buf(seconds);
    final n = out.length;
    final t = Typist<void>(0, 0)..on = true;
    final s = samples;
    void key(double when, KeyKind kind) {
      final buf = switch (kind) {
        KeyKind.key => _pick(s.keys),
        KeyKind.mouse => s.mouse,
        _ => _pick(s.spaces),
      };
      final level = switch (kind) {
        KeyKind.enter => 0.55,
        KeyKind.space => 0.4,
        KeyKind.mouse => 0.3,
        KeyKind.key => _rand(0.24, 0.34),
      };
      final rate = _rand(0.93, 1.07);
      final len = (buf.length / rate).ceil();
      final k = playBuffer(len, sr, buf, rate: rate);
      final at = _at(when);
      for (var i = 0; i < len; i++) {
        out[(at + i) % n] += k[i] * level;
      }
    }

    // Start mid-flow, and step the Typist's clock along to the end.
    t.next = 0.01;
    for (var now = 0.0; now < seconds - 0.2; now += 0.05) {
      t.schedule(now, rng, (when, kind) {
        if (when < seconds) key(when, kind);
      });
    }
    return out;
  }
}

// ---- What the desktop app renders when it starts ---------------------------------------------------------

/// The batches the desktop app renders at startup, in order: what matters most first.
enum Bank { alerts, room, rest }

/// Renders one [Bank] at [sr]: name → PCM (mono). Variants of a sound are `name.0`, `name.1`…
/// Runs in a background isolate (Isolate.run), so it's a top-level function of plain data.
Map<String, Float32List> renderBank(int sr, Bank bank, [int seed = 0]) {
  final r = OfficeRender(sr, seed == 0 ? null : math.Random(seed));
  final s = r.samples;
  final out = <String, Float32List>{};
  void many(String name, int n, Float32List Function() render) {
    for (var i = 0; i < n; i++) {
      out['$name.$i'] = render();
    }
  }

  switch (bank) {
    case Bank.alerts:
      // The gong and the dings first, then the steps and the keys (just samples).
      out['ding.done'] = r.ding(Ding.done);
      out['ding.needsInput'] = r.ding(Ding.needsInput);
      many('gong.merged', 2, () => r.gongStroke(1));
      many('gong.hit', 3, () => r.gongStroke(0.6 + 0.2 * r.rng.nextDouble()));
      out['gong.queue'] = r.gongQueue();
      for (var i = 0; i < s.steps.length; i++) {
        out['step.$i'] = s.steps[i];
      }
      out['rustle'] = s.rustle;
      out['drop'] = s.drop;
    case Bank.room:
      out['room'] = r.roomTone();
      out['fridge'] = r.fridgeHum();
      out['roof'] = r.roof();
      for (final (name, cutoff) in const [('office', 1300.0), ('garage', 2600.0), ('out', 6500.0)]) {
        out['rain.$name'] = r.rainHiss(cutoff);
      }
      many('typing', 3, () => r.typing(45));
    case Bank.rest:
      many('coffee', 2, r.coffee);
      many('bark2', 2, () => r.bark(2));
      many('bark3', 2, () => r.bark(3));
      many('yip', 2, r.yip);
      many('birds', 8, r.birds);
      many('crickets', 5, r.crickets);
      out['phone.2'] = r.phone(2);
      out['phone.3'] = r.phone(3);
      many('creak', 4, r.creak);
      many('pour', 2, r.pour);
      many('hiccup', 2, r.hiccup);
      out['arcade.land'] = r.arcade('land');
      out['arcade.over'] = r.arcade('over');
      for (var lines = 0; lines <= 4; lines++) {
        out['arcade.clear$lines'] = r.arcade('clear', lines);
      }
      for (final kind in const ['bounce', 'rim', 'board', 'score']) {
        for (final (i, loud) in ballLevels.indexed) {
          out['ball.$kind.$i'] = r.ball(kind, loud);
        }
      }
  }
  return out;
}

/// How hard the basketball's sounds are rendered: the one nearest a hit's own is played, scaled.
const List<double> ballLevels = [0.2, 0.45, 0.7, 1];
