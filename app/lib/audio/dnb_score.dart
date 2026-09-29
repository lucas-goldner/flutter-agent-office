// The DJ's set on the rooftop as numbers: the pure half of dnb.dart (a port of dnb.ts), with no Web
// Audio in it, so it runs (and is tested) on the Dart VM, and the lights on the rig can follow it
// even where there's no sound (the desktop app, or someone with the music off).
//
// The set is a run of tracks of 96 bars each: an intro, a build, the drop, a breakdown, another build
// and a second drop. Each track has its own key, chords, groove and bassline, picked from its number.
// Every note follows from the office's clock (see djTime), so everyone on the roof hears the same bar
// at the same moment, and the lights flash on the same kicks and snares (see djFrame).

import 'dart:math' as math;
import 'dart:typed_data';

import 'score.dart' show mulberry;

const double djBpm = 172;

/// A 16th, a beat and a bar, in seconds.
const double djStep = 60 / djBpm / 4;
const double djBeat = djStep * 4;
const double djBar = djStep * 16;
const int trackBars = 96;

/// The set started here, on the office's clock; it keeps the numbers small.
final int _epoch = DateTime.utc(2026).millisecondsSinceEpoch;

/// How far into the set it is (seconds) at [officeMs] on the office's clock.
double djTime(double officeMs) => (officeMs - _epoch) / 1000;

enum Part { intro, build, drop, breakdown }

class Section {
  const Section(this.part, this.bar, this.bars, this.second);

  final Part part;

  /// The bar within this part, and how many it has.
  final int bar;
  final int bars;

  /// Past the first drop: the breakdown, the second build and the second drop.
  final bool second;
}

const List<(Part, int)> _sections = [
  (Part.intro, 16),
  (Part.build, 8),
  (Part.drop, 32),
  (Part.breakdown, 16),
  (Part.build, 8),
  (Part.drop, 16),
];

Section sectionOf(int barInTrack) {
  var start = 0;
  var second = false;
  for (final (part, bars) in _sections) {
    if (barInTrack < start + bars) return Section(part, barInTrack - start, bars, second);
    if (part == Part.drop) second = true;
    start += bars;
  }
  return const Section(Part.drop, 0, 16, true);
}

/// A bar of 16ths each: x hits, o hits softly (a ghost note).
class Groove {
  const Groove(this.kick, this.snare);
  final String kick;
  final String snare;
}

const List<Groove> _grooves = [
  Groove('x.........x.....', '....x..o....x..o'),
  Groove('x.........x..x..', '....x.......x.o.'),
  Groove('x......x..x.....', '.o..x..o....x...'),
  Groove('x.x.......x.....', '....x....o..x..o'),
  Groove('x.........xx....', '....x..o....x...'),
];

/// Chords as degrees of the minor scale, one every two bars.
const List<List<int>> _progressions = [
  [0, 5, 2, 6],
  [0, 6, 5, 6],
  [0, 3, 5, 4],
  [5, 3, 0, 6],
  [0, 5, 3, 4],
];
const List<int> _minor = [0, 2, 3, 5, 7, 8, 10];

const List<List<int>> _arps = [
  [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 4, 3, 2, 1, 2, 3],
  [0, 2, 1, 3, 2, 4, 3, 1, 0, 2, 1, 3, 2, 4, 3, 5],
  [0, 0, 2, 0, 3, 0, 2, 4, 0, 0, 2, 0, 3, 2, 4, 3],
];

enum Bass { reese, roller }

class Track {
  const Track({
    required this.root,
    required this.prog,
    required this.groove,
    required this.bass,
    required this.wah,
    required this.arp,
    required this.horn,
    required this.hue,
  });

  /// The lowest bass note (MIDI, around F1).
  final int root;
  final List<int> prog;
  final Groove groove;

  /// Long notes that growl (a reese), or short rolling ones.
  final Bass bass;

  /// How the bass's filter moves through each bar, an 8th at a time: h opens it, l closes it.
  final String wah;

  /// Which chord note the arpeggio plays on each 16th.
  final List<int> arp;

  /// An air horn when the first drop lands.
  final bool horn;

  /// The lights' color for this track, 0–1 round the color wheel.
  final double hue;
}

(int, Track)? _cached;

/// Track [n] of the set: the same for everyone.
Track trackAt(int n) {
  final c = _cached;
  if (c != null && c.$1 == n) return c.$2;
  final r = mulberry(n * 7919 + 13);
  T pick<T>(List<T> xs) => xs[(r() * xs.length).floor()];
  // In the TS's order, one random number after another.
  final root = pick(const [28, 29, 30, 31, 33]);
  final prog = pick(_progressions);
  final groove = pick(_grooves);
  final bass = r() < 0.6 ? Bass.reese : Bass.roller;
  final wah = List.generate(8, (i) => i == 0 || r() < 0.45 ? 'h' : 'l').join();
  final arp = pick(_arps);
  final horn = r() < 0.65;
  final hue = r();
  final track = Track(root: root, prog: prog, groove: groove, bass: bass, wah: wah, arp: arp, horn: horn, hue: hue);
  _cached = (n, track);
  return track;
}

/// A note of the track's minor scale: [degree] steps up from [root] (MIDI).
int scaleNote(int root, int degree) {
  final d = ((degree % 7) + 7) % 7;
  return root + _minor[d] + 12 * (degree / 7).floor();
}

/// What happens on one 16th of the set.
class Plan {
  Plan(this.track, this.section, this.s, this.chord);

  final Track track;
  final Section section;

  /// 0–15 within the bar.
  final int s;

  /// The chord's degree.
  final int chord;

  /// How hard each drum hits, 0 for not at all.
  double kick = 0;
  double snare = 0;
  double hat = 0;
  bool openHat = false;
  double shaker = 0;
}

int _floorDiv(int a, int b) => (a / b).floor();

/// The 16th [k] of the set (0 is the set's first).
Plan plan(int k) {
  final bar = _floorDiv(k, 16);
  final s = ((k % 16) + 16) % 16;
  final n = _floorDiv(bar, trackBars);
  final b = bar - n * trackBars;
  final track = trackAt(n);
  final section = sectionOf(b);
  final chord = track.prog[(b ~/ 2) % track.prog.length];
  double hit(String p) => p[s] == 'x' ? 1 : (p[s] == 'o' ? 0.35 : 0);
  final out = Plan(track, section, s, chord);
  final g = track.groove;
  final sb = section.bar;
  switch (section.part) {
    case Part.intro:
      // Hats alone at first, then the whole break, muffled (the drum filter opens up as it goes).
      out.hat = s % 2 == 0 ? (s % 4 == 2 ? 0.8 : 0.5) : 0;
      if (sb >= 4) {
        out.kick = hit(g.kick);
        out.snare = hit(g.snare);
      }
    case Part.build:
      // Four to the floor under a snare roll that gets quicker every couple of bars, then a beat of nothing.
      final last = sb == section.bars - 1 && s >= 12;
      if (!last) {
        if (sb < 6 && s % 4 == 0) out.kick = 0.8;
        final every = sb < 3 ? 4 : (sb < 5 ? 2 : 1);
        if (s % every == 0) out.snare = 0.35 + 0.65 * ((sb * 16 + s) / (section.bars * 16));
        out.hat = s % 2 == 0 ? 0.4 : 0;
      }
    case Part.drop:
      final fill = sb % 8 == 7;
      out.kick = fill && s >= 10 ? 0 : hit(g.kick);
      out.snare = fill && s >= 12 ? 0.55 + (s - 12) * 0.15 : hit(g.snare);
      out.hat = s % 2 == 0 ? (s % 4 == 2 ? 1 : 0.6) : 0;
      out.openHat = s == 14 && sb % 2 == 1;
      out.shaker = s % 2 == 1 ? 0.7 : 0.4;
    case Part.breakdown:
      // The pads and the arpeggio alone, then a half-time beat creeping back in.
      if (sb >= 8) {
        out.kick = s == 0 ? 0.8 : 0;
        out.snare = s == 8 ? 0.8 : 0;
        out.hat = s % 4 == 2 ? 0.6 : 0;
      }
  }
  return out;
}

/// What the lights go by: where the set is, and what just hit.
class DjFrame {
  const DjFrame({
    required this.beats,
    required this.beat,
    required this.kick,
    required this.snare,
    required this.energy,
    required this.part,
    required this.rise,
    required this.sinceDrop,
    required this.track,
    required this.hue,
  });

  /// Beats since the set began.
  final double beats;

  /// 1 on each beat, falling to 0 before the next.
  final double beat;

  /// 1 as a kick or a snare lands, falling off fast.
  final double kick;
  final double snare;

  /// How hard it's going: low in a breakdown, 1 in a drop.
  final double energy;
  final Part part;

  /// 0 → 1 through a build.
  final double rise;

  /// Seconds since the drop landed (infinity outside a drop).
  final double sinceDrop;

  /// Which track of the set, and its color (0–1 round the wheel).
  final int track;
  final double hue;
}

/// Where the set is at [at] (see djTime), and what just hit.
DjFrame djFrame(double at) {
  final k = (at / djStep).floor();
  final p = plan(k);
  final sec = p.section;
  final beats = at / djBeat;
  final beat = math.pow(1 - (beats - beats.floor()), 3).toDouble();
  var kick = 0.0;
  var snare = 0.0;
  // The last kick and snare within a beat, fading from when they hit.
  for (var j = 0; j < 4 && !(kick != 0 && snare != 0); j++) {
    final q = j == 0 ? p : plan(k - j);
    final since = at - (k - j) * djStep;
    if (kick == 0 && q.kick >= 0.5) kick = math.exp(-since * 9);
    if (snare == 0 && q.snare >= 0.5) snare = math.exp(-since * 11);
  }
  final s16 = ((k % 16) + 16) % 16;
  final through = (sec.bar + s16 / 16) / sec.bars;
  final energy = switch (sec.part) {
    Part.drop => 1.0,
    Part.build => 0.45 + 0.5 * through,
    Part.intro => 0.3 + 0.2 * through,
    Part.breakdown => sec.bar >= 8 ? 0.35 : 0.18,
  };
  final n = _floorDiv(_floorDiv(k, 16), trackBars);
  return DjFrame(
    beats: beats,
    beat: beat,
    kick: kick,
    snare: snare,
    energy: sec.second && sec.part == Part.drop ? 1 : energy,
    part: sec.part,
    rise: sec.part == Part.build ? through : 0,
    sinceDrop: sec.part == Part.drop ? (sec.bar * 16 + s16) * djStep + (at - k * djStep) : double.infinity,
    track: n,
    hue: p.track.hue,
  );
}

/// What the DJ booth's hint says the set is doing.
String djDoing(Part part) => switch (part) {
  Part.drop => '🔥 the drop',
  Part.build => 'building up…',
  Part.breakdown => 'the breakdown',
  Part.intro => 'mixing in the next track',
};

/// A soft-clipping curve for the bass's grit.
Float32List driveCurve(double amount) {
  const n = 1024;
  final c = Float32List(n);
  double tanh(double x) {
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }

  for (var i = 0; i < n; i++) {
    final x = (i / (n - 1)) * 2 - 1;
    c[i] = tanh(x * amount) / tanh(amount);
  }
  return c;
}
