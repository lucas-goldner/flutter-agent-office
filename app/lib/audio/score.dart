// The jukebox's tunes as numbers: the pure half of music.dart, with no Web Audio in it, so it runs
// (and is tested) on the Dart VM.
//
// Every note follows from the tune and how far into it you are, so everyone on the floor who starts
// from the same moment hears exactly the same bar. The random numbers here are the TS client's,
// bit for bit (Math.imul, mulberry32), so a Dart client and a TS one agree too.

import 'dart:math' as math;

/// A tune: chords, drum patterns, a bass line and how the keys comp, plus the seed of its melody.
class Tune {
  const Tune({
    required this.bpm,
    required this.swing,
    required this.chords,
    required this.kick,
    required this.snare,
    required this.hat,
    required this.bass,
    required this.comp,
    required this.seed,
  });

  final double bpm;

  /// How late every other 16th lands, as a fraction of a 16th.
  final double swing;

  /// A bar each: the bass root, then the notes the keys play (MIDI numbers).
  final List<List<int>> chords;

  /// A bar of 16ths each: x hits, o hits softly.
  final String kick;
  final String snare;
  final String hat;

  /// (16th, length in 16ths, semitones above the root).
  final List<(int, int, int)> bass;

  /// When the keys strike the chord: (16th, length in 16ths, how hard).
  final List<(int, int, double)> comp;

  /// Picks the melody.
  final int seed;
}

const Map<String, Tune> tunes = {
  'rainy-window': Tune(
    bpm: 74,
    swing: 0.16,
    chords: [
      [41, 57, 60, 64, 67], // Fmaj9
      [40, 55, 59, 62, 64], // Em7
      [38, 53, 57, 60, 64], // Dm9
      [36, 55, 58, 62, 64], // C9
    ],
    kick: 'x.........x.....',
    snare: '....x.......x...',
    hat: 'x.o.x.o.x.o.x.oo',
    bass: [(0, 7, 0), (10, 4, 0), (14, 2, 7)],
    comp: [(0, 10, 1), (11, 5, 0.6)],
    seed: 7,
  ),
  'coffee-break': Tune(
    bpm: 88,
    swing: 0.22,
    chords: [
      [38, 53, 57, 60, 64], // Dm9
      [43, 53, 59, 64, 69], // G13
      [36, 52, 55, 59, 62], // Cmaj9
      [45, 55, 61, 65], // A7♭13
    ],
    kick: 'x......x..x.....',
    snare: '....x.......x..o',
    hat: 'x.oxx.o.x.oxx.o.',
    bass: [(0, 5, 0), (6, 2, 7), (8, 5, 0), (14, 2, 12)],
    comp: [(0, 6, 1), (6, 3, 0.65), (10, 6, 0.85)],
    seed: 21,
  ),
  'late-commit': Tune(
    bpm: 70,
    swing: 0.12,
    chords: [
      [45, 60, 64, 67, 71], // Am9
      [41, 57, 59, 64], // Fmaj7♯11
      [38, 53, 57, 60, 64], // Dm9
      [40, 56, 59, 62, 65], // E7♭9
    ],
    kick: 'x......ox.x.....',
    snare: '....x.......x...',
    hat: 'x.o.x.o.x.o.x.o.',
    bass: [(0, 6, 0), (8, 2, 0), (10, 5, 0)],
    comp: [(0, 10, 1), (12, 4, 0.6)],
    seed: 3,
  ),
  'green-build': Tune(
    bpm: 94,
    swing: 0.1,
    chords: [
      [43, 59, 62, 66, 69], // Gmaj9
      [42, 57, 61, 64], // F♯m7
      [40, 55, 59, 62, 66], // Em9
      [45, 55, 61, 66], // A13
    ],
    kick: 'x.....x...x.....',
    snare: '....x.......x...',
    hat: 'x.xox.xox.xox.xo',
    bass: [(0, 3, 0), (3, 2, 12), (6, 3, 0), (10, 3, 7), (14, 2, 0)],
    comp: [(0, 3, 0.9), (4, 2, 0.6), (8, 3, 0.8), (11, 4, 0.7)],
    seed: 11,
  ),
};

/// Rhythms for a bar of melody: (16th, length in 16ths).
const List<List<(int, int)>> _cells = [
  [(0, 4), (6, 2), (8, 6)],
  [(2, 2), (4, 4), (10, 4)],
  [(0, 6), (8, 2), (10, 2), (12, 4)],
  [(4, 2), (6, 2), (8, 8)],
  [(0, 3), (3, 3), (6, 6)],
];

/// The last bar of each half of a phrase just rests on a note or two.
const List<List<(int, int)>> _endings = [
  [(0, 12)],
  [(2, 2), (4, 10)],
];

/// A melody note: (16th, length in 16ths, MIDI note).
typedef Note = (int step, int len, int midi);

/// Eight bars of melody, picked from each bar's chord tones by the tune's seed, then repeated.
List<List<Note>> melodyFor(Tune t) {
  final rand = mulberry(t.seed);
  var prev = 74;
  final bars = <List<Note>>[];
  for (var b = 0; b < 8; b++) {
    final chord = t.chords[b % t.chords.length];
    final tones = <int>[];
    for (var m = 67; m <= 83; m++) {
      if (chord.any((c) => (c - m) % 12 == 0)) tones.add(m);
    }
    final cells = b % 4 == 3 ? _endings : _cells;
    final cell = cells[(rand() * cells.length).floor()];
    bars.add([
      for (final (step, len) in cell) (step, len, prev = _nextNote(tones, prev, rand)),
    ]);
  }
  return bars;
}

/// Mostly a step or two from the last note, now and then a leap.
int _nextNote(List<int> tones, int prev, double Function() rand) {
  final near = <int>[];
  for (final m in tones) {
    // The TS draws a fresh random number for every tone it looks at.
    if ((m - prev).abs() <= (rand() < 0.2 ? 7 : 4) && m != prev) near.add(m);
  }
  final pool = near.isNotEmpty ? near : tones;
  return pool[(rand() * pool.length).floor()];
}

/// Which parts play in a bar of a 32-bar round: the keys alone, then everything, a breakdown, and everything again.
typedef Section = ({bool drums, bool bass, bool melody});

Section section(int bar) {
  final b = bar % 32;
  return (drums: b >= 4 && !(b >= 24 && b < 28), bass: b >= 2, melody: (b >= 8 && b < 24) || b >= 28);
}

/// The instruments of a tune.
enum Voice { kick, snare, hat, bass, key, lead }

/// One note a 16th starts: on `voice`, `delay` seconds after the 16th (the keys are humanized a little),
/// lasting `len` seconds. `midi` is 0 for the drums.
class NoteEvent {
  const NoteEvent(this.voice, {this.delay = 0, this.midi = 0, this.len = 0, this.vel = 1});

  final Voice voice;
  final double delay;
  final int midi;
  final double len;
  final double vel;

  @override
  String toString() => 'NoteEvent(${voice.name}, delay: $delay, midi: $midi, len: $len, vel: $vel)';
}

/// A tune and its melody, with the maths of where each 16th falls and what it plays.
class Score {
  Score(String id) : this.of(tunes[id] ?? tunes.values.first);

  Score.of(this.tune) : melody = melodyFor(tune), step = 60 / tune.bpm / 4;

  final Tune tune;
  final List<List<Note>> melody;

  /// How long a 16th is, in seconds.
  final double step;

  /// When the `k`th 16th lands, in seconds into the tune, with every other one swung late.
  double stepTime(int k) => (k + (k.isOdd ? tune.swing : 0)) * step;

  /// 1 on each beat, falling to 0 before the next, for the jukebox's lights. `at` is seconds into the tune.
  double beat(double at) {
    final beats = at / (step * 4);
    final frac = beats - beats.floor();
    final pulse = (1 - frac) * (1 - frac);
    return section((beats / 4).floor()).drums ? pulse : pulse * 0.35;
  }

  /// Everything the `k`th 16th of the tune starts.
  List<NoteEvent> eventsAt(int k) {
    final t = tune;
    final bar = k ~/ 16;
    final s = k % 16;
    final on = section(bar);
    final chord = t.chords[bar % t.chords.length];
    double len(int n) => n * step;
    final out = <NoteEvent>[];
    if (on.drums) {
      double hit(String p) => p[s] == 'x' ? 1 : (p[s] == 'o' ? 0.55 : 0);
      if (hit(t.kick) > 0) out.add(NoteEvent(Voice.kick, vel: hit(t.kick)));
      if (hit(t.snare) > 0) out.add(NoteEvent(Voice.snare, vel: hit(t.snare)));
      if (hit(t.hat) > 0) out.add(NoteEvent(Voice.hat, vel: hit(t.hat) * (0.7 + 0.3 * hash(k, t.seed))));
    }
    if (on.bass) {
      for (final (at, n, up) in t.bass) {
        if (at == s) out.add(NoteEvent(Voice.bass, midi: chord[0] + up, len: len(n)));
      }
    }
    for (final (at, n, vel) in t.comp) {
      if (at != s) continue;
      for (final m in chord.skip(1)) {
        out.add(NoteEvent(Voice.key, delay: hash(k, m) * 0.012, midi: m, len: len(n), vel: vel));
      }
    }
    if (on.melody) {
      for (final (at, n, m) in melody[bar % 8]) {
        if (at == s) out.add(NoteEvent(Voice.lead, midi: m, len: len(n)));
      }
    }
    return out;
  }
}

/// How far ahead the player schedules, in seconds.
const double lookahead = 1.1;

/// Lines a tune up with the audio clock and says which 16ths to schedule, and when on that clock.
class TuneClock {
  TuneClock(this.score);

  final Score score;

  /// Audio-clock time minus tune time: where the tune's start falls on the audio clock.
  double offset = double.nan;

  /// The next 16th to schedule.
  int next = -1;

  /// The 16ths to play now that it's `at` seconds into the tune and `now` on the audio clock:
  /// (16th, when on the audio clock).
  List<(int, double)> due(double at, double now) {
    // Line the tune up with the audio clock, and again whenever the two drift apart.
    final off = now - at;
    final drift = (off - offset).abs();
    if (!(drift < 0.03)) {
      offset = off;
      // A jump (a suspended context, a computer waking up): pick up from now rather than catch up.
      if (!(drift < 0.5)) next = -1;
    }
    if (next < 0) next = math.max(0, (at / score.step).ceil());
    final until = at + lookahead;
    final out = <(int, double)>[];
    for (; score.stepTime(next) < until; next++) {
      final t = score.stepTime(next);
      if (t >= at - 0.02) out.add((next, math.max(now, t + offset)));
    }
    return out;
  }
}

/// MIDI note to Hz.
double mtof(num m) => 440 * math.pow(2, (m - 69) / 12).toDouble();

// ---- The TS client's random numbers, bit for bit -----------------------------------------------------

const int _two32 = 0x100000000;

int _u32(int v) => v % _two32;

/// JS's Math.imul, on unsigned 32-bit values, safe under dart2js (no product goes past 2^53).
int imul(int a, int b) {
  a = _u32(a);
  b = _u32(b);
  final ah = a >>> 16, al = a & 0xffff;
  final bh = b >>> 16, bl = b & 0xffff;
  return _u32(al * bl + _u32(ah * bl + al * bh) % 0x10000 * 0x10000);
}

/// The same 0–1 for the same numbers, on everyone's machine.
double hash(int a, int b) {
  var h = _u32(imul(_u32(a) ^ 0x9e3779b9, 0x85ebca6b) ^ imul(_u32(b + 0x632be5ab), 0xc2b2ae35));
  h ^= h >>> 15;
  h = imul(h, 0x2c1b3c6d);
  h ^= h >>> 12;
  return _u32(h) / 4294967296;
}

/// mulberry32: a seeded 0–1 generator.
double Function() mulberry(int seed) {
  var a = _u32(seed);
  return () {
    a = _u32(a + 0x6d2b79f5);
    var t = a;
    t = imul(t ^ (t >>> 15), t | 1);
    t = _u32(t ^ _u32(t + imul(t ^ (t >>> 7), t | 61)));
    return _u32(t ^ (t >>> 14)) / 4294967296;
  };
}
