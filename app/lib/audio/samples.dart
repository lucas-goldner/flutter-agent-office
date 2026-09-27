// The office's sound samples, computed once when audio starts: key clicks, footsteps, paper, a
// raindrop, and the noises the rest is made of. Plain Float32Lists (sound.dart and music.dart copy
// them into AudioBuffers), so they're made and tested on the VM too.

import 'dart:math' as math;
import 'dart:typed_data';

/// `seconds` of `next(t)` at `sr` samples a second, normalized to `peak` if given.
Float32List sample(int sr, double seconds, double Function(double t) next, [double? peak]) {
  final d = Float32List((sr * seconds).ceil());
  for (var i = 0; i < d.length; i++) {
    d[i] = next(i / sr);
  }
  if (peak != null && peak > 0) {
    var max = 0.0;
    for (final v in d) {
      max = math.max(max, v.abs());
    }
    if (max > 0) {
      for (var i = 0; i < d.length; i++) {
        d[i] *= peak / max;
      }
    }
  }
  return d;
}

/// A buffer whose end runs smoothly into its start, so it loops without a click.
Float32List loopable(int sr, double seconds, double Function() next) {
  final n = (sr * seconds).ceil();
  final fade = (sr * 0.25).floor();
  final raw = Float32List(n + fade);
  for (var i = 0; i < raw.length; i++) {
    raw[i] = next();
  }
  final d = Float32List.fromList(raw.sublist(0, n));
  for (var i = 0; i < fade; i++) {
    final k = i / fade;
    d[i] = raw[i] * math.sqrt(k) + raw[n + i] * math.sqrt(1 - k);
  }
  return d;
}

double Function() brownNoise(math.Random rng) {
  var last = 0.0;
  return () {
    last = (last + 0.02 * (rng.nextDouble() * 2 - 1)) / 1.02;
    return last * 3.5;
  };
}

/// Wanders between random levels, holding each for `min`–`max` seconds.
double Function() lumpy(int sr, double min, double max, math.Random rng) {
  var level = 0.0, target = 0.0;
  var hold = 0;
  return () {
    if (--hold <= 0) {
      target = math.pow(rng.nextDouble(), 2).toDouble();
      hold = ((min + rng.nextDouble() * (max - min)) * sr).floor();
    }
    level += (target - level) * (100 / sr);
    return level;
  };
}

/// A key bottoming out, a bright tick over a short woody thock, then a softer tick as it springs back.
Float32List keyClick(int sr, math.Random rng, {required double body, required double bright, required double release, required double decay, required double len}) {
  var prev = 0.0, hiss = 0.0, low = 0.0;
  return sample(sr, len, (t) {
    final w = rng.nextDouble() * 2 - 1;
    hiss += (w - prev - hiss) * 0.5; // high-passed, then the harshest top taken off
    prev = w;
    low += (w - low) * 0.15;
    var v = hiss * math.exp(-t * 700) * bright + (math.sin(2 * math.pi * body * t) * 0.5 + low) * math.exp(-t * decay);
    final r = t - release;
    if (r > 0) v += hiss * math.exp(-r * 900) * bright * 0.45;
    return v;
  }, 0.9);
}

/// A soft shoe on carpet: a muffled thud and a little scuff.
Float32List footstep(int sr, math.Random rng) {
  var low = 0.0, prev = 0.0;
  final scuffAt = 0.025 + rng.nextDouble() * 0.02;
  return sample(sr, 0.25, (t) {
    final w = rng.nextDouble() * 2 - 1;
    low += (w - low) * 0.03;
    final attack = math.min(1.0, t / 0.004);
    var v = (low * 3 + math.sin(2 * math.pi * 62 * t) * 0.5) * attack * math.exp(-t * 30);
    final s = t - scuffAt;
    if (s > 0) v += (w - prev) * 0.06 * math.exp(-s * 50);
    prev = w;
    return v;
  }, 0.9);
}

/// Paper being shuffled: crackly mid-range noise in uneven bursts.
Float32List rustleSample(int sr, math.Random rng) {
  const len = 0.8;
  var a = 0.0, b = 0.0, amp = 0.0, target = 0.0;
  var hold = 0;
  return sample(sr, len, (t) {
    final w = rng.nextDouble() * 2 - 1;
    a += (w - a) * 0.5;
    b += (w - b) * 0.05;
    if (--hold <= 0) {
      target = math.pow(rng.nextDouble(), 3).toDouble();
      hold = ((0.008 + rng.nextDouble() * 0.022) * sr).floor();
    }
    amp += (target - amp) * 0.02;
    return (a - b) * amp * math.sin((math.pi * t) / len);
  }, 0.8);
}

/// A raindrop hitting the glass.
Float32List dropSample(int sr, math.Random rng) => sample(
  sr,
  0.06,
  (t) => (math.sin(2 * math.pi * 2400 * t * (1 - t * 5)) * 0.6 + (rng.nextDouble() * 2 - 1) * 0.4) * math.exp(-t * 110),
  0.9,
);

Float32List whiteNoise(int sr, double seconds, math.Random rng) => sample(sr, seconds, (_) => rng.nextDouble() * 2 - 1);

/// The office's samples.
class OfficeSamples {
  OfficeSamples(int sr, [math.Random? random]) : this._(sr, random ?? math.Random());

  OfficeSamples._(int sr, math.Random rng)
    : keys = [
        for (var i = 0; i < 6; i++)
          keyClick(sr, rng, body: _r(rng, 190, 300), bright: _r(rng, 0.7, 1), release: _r(rng, 0.06, 0.09), decay: 95, len: 0.12),
      ],
      spaces = [for (var i = 0; i < 2; i++) keyClick(sr, rng, body: _r(rng, 105, 130), bright: 0.55, release: _r(rng, 0.09, 0.12), decay: 55, len: 0.2)],
      mouse = keyClick(sr, rng, body: 900, bright: 1, release: 0.07, decay: 400, len: 0.1),
      steps = [for (var i = 0; i < 3; i++) footstep(sr, rng)],
      rustle = rustleSample(sr, rng),
      drop = dropSample(sr, rng),
      brown = loopable(sr, 6, brownNoise(rng)),
      white = whiteNoise(sr, 5, rng),
      gurgle = loopable(sr, 4, lumpy(sr, 0.03, 0.11, rng));

  final List<Float32List> keys;
  final List<Float32List> spaces;
  final Float32List mouse;
  final List<Float32List> steps;
  final Float32List rustle;

  /// A raindrop hitting the glass.
  final Float32List drop;
  final Float32List brown;
  final Float32List white;

  /// A slow, lumpy 0–1 signal for wobbling other sounds' volume.
  final Float32List gurgle;

  static double _r(math.Random rng, double a, double b) => a + rng.nextDouble() * (b - a);
}

/// The jukebox's samples: noise for the drums, the needle's crackle, and a small dark room.
class TuneSamples {
  TuneSamples(int sr, [math.Random? random]) : this._(sr, random ?? math.Random());

  TuneSamples._(int sr, math.Random rng) : noise = whiteNoise(sr, 3, rng), crackle = _crackle(sr, rng), room = [_room(sr, rng), _room(sr, rng)];

  final Float32List noise;
  final Float32List crackle;

  /// A small, dark room to put the keys and snare in: two channels.
  final List<Float32List> room;

  /// Pops of every size, a few dozen a second, over a whisper of hiss.
  static Float32List _crackle(int sr, math.Random rng) {
    final cd = Float32List(sr * 5);
    for (var i = 0; i < cd.length; i++) {
      cd[i] = (rng.nextDouble() * 2 - 1) * 0.04;
    }
    for (var n = 0; n < 5 * 28; n++) {
      final at = (rng.nextDouble() * (cd.length - 200)).floor();
      final amp = math.pow(rng.nextDouble(), 3) * (rng.nextDouble() < 0.5 ? -1 : 1);
      final width = 2 + (rng.nextDouble() * 30).floor();
      for (var i = 0; i < width * 4; i++) {
        cd[at + i] += amp * math.exp(-i / width) * (i.isOdd ? -0.6 : 1);
      }
    }
    return cd;
  }

  static Float32List _room(int sr, math.Random rng) {
    final d = Float32List((sr * 1.6).floor());
    var low = 0.0;
    for (var i = 0; i < d.length; i++) {
      low += (rng.nextDouble() * 2 - 1 - low) * 0.25;
      d[i] = low * math.exp((-i / sr) * 3.4);
    }
    return d;
  }
}
