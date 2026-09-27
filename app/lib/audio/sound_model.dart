// The pure half of sound.dart: where the office's sounds come from, how the jukebox fades across the
// room, and the rhythm of a worker typing. No Web Audio here, so it runs (and is tested) on the VM.

import 'dart:math' as math;

import '../shared/layout.dart';

class Pos {
  const Pos(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;
}

/// Where you hear from: your head, facing where the camera looks (fx, fz).
class SoundListener extends Pos {
  const SoundListener({required double x, required double y, required double z, required this.fx, required this.fz}) : super(x, y, z);

  final double fx;
  final double fz;
}

/// What the jukebox on your floor plays: a tune or a stream, and when it started.
class JukeboxPlay {
  const JukeboxPlay({required this.track, this.url, required this.startedAt, required this.since});

  final String track;
  final String? url;

  /// When it started on the office's clock, which tells one play of a track from the next.
  final double startedAt;

  /// When it started on our own clock (the store's `nowMs()`), in ms.
  final double since;

  /// The same play, maybe sent again after a reconnect or timed better once the clocks are compared.
  bool samePlayAs(JukeboxPlay o) => startedAt == o.startedAt && track == o.track && url == o.url;
}

/// The dog's voice (see world/dog.ts).
abstract interface class DogSounds {
  void bark(double x, double z, int times);

  /// A happy little yip, when someone pets it.
  void yip(double x, double z);
}

enum StepKind { walk, land }

/// Two notes up when a worker is done, a three-note nudge when it needs input.
enum Ding {
  done,
  needsInput;

  /// From a worker status ('done' or 'needs_input').
  static Ding? fromStatus(String status) => switch (status) {
    'done' => Ding.done,
    'needs_input' => Ding.needsInput,
    _ => null,
  };
}

/// How the jukebox fades with distance: the same curve for its tunes (a panner) and a stream (by hand).
const double musicRef = 2.5;
const double musicRolloff = 1.3;

// The kitchen props (office.ts puts the kitchen at x -14.5, z 12.2).
const Pos coffeeMachine = Pos(-15.7, 1.4, 12.2);
const Pos fridge = Pos(-11.3, 1.1, 12.2);

/// Just outside the office's windows (not the loft's).
final List<Pos> soundWindows = List.unmodifiable([
  for (final o in windows)
    if (o.y0 < 2)
      o.wall == Side.south || o.wall == Side.north
          ? Pos(o.u, 2.4, o.wall == Side.south ? Floor.maxZ + 1.5 : Floor.minZ - 1.5)
          : Pos(o.wall == Side.west ? Floor.minX - 1.5 : Floor.maxX + 1.5, 2.4, o.u),
]);

/// The middle of the gong's disc.
const Pos gongAt = Pos(Gong.x, Gong.height - 1.36, Gong.z);

/// The jukebox's speaker.
const Pos jukeboxAt = Pos(Jukebox.x, Jukebox.y, Jukebox.z);

/// A gong's overtones don't line up like a string's: (ratio to the lowest, loudness, seconds to die away).
const List<(double, double, double)> gongPartials = [
  (1, 0.8, 7),
  (1.51, 0.75, 5.5),
  (2.13, 0.65, 4.6),
  (2.66, 0.55, 3.8),
  (3.19, 0.45, 3.1),
  (3.84, 0.38, 2.5),
  (4.48, 0.3, 2),
  (5.27, 0.22, 1.6),
  (6.35, 0.16, 1.2),
  (7.61, 0.1, 0.9),
  (9.08, 0.07, 0.6),
];

/// Where your ears are: in the office, where rain is muffled by the glass, in the garage, or out in it.
enum Where { office, garage, out }

Where whereIs(Pos l) {
  bool under(double m) => l.x > Floor.minX - m && l.x < Floor.maxX + m && l.z > Floor.minZ - m && l.z < Floor.maxZ + m;
  if (under(0) && l.y > -0.5) return Where.office;
  return under(0.3) ? Where.garage : Where.out;
}

/// How loud the rain's hiss is (before easing towards it).
double rainLevel(double rain, Where where) =>
    rain < 0.01 ? 0 : (where == Where.out ? 0.16 : (where == Where.garage ? 0.11 : 0.06)) * math.pow(rain, 0.8);

/// How bright the rain's hiss is: muffled by the glass, or the garage, or not at all.
double rainCutoff(Where where) => where == Where.out ? 6500 : (where == Where.garage ? 2600 : 1300);

double jukeboxDistance(Pos l) {
  final dx = l.x - jukeboxAt.x, dy = l.y - jukeboxAt.y, dz = l.z - jukeboxAt.z;
  return math.sqrt(dx * dx + dy * dy + dz * dz);
}

/// The jukebox is muffled the further you are from it: its lowpass cutoff at distance `d`.
double musicCutoffAt(double d) => d < 5 ? 16000 : math.max(1600, 16000 * math.pow(5 / d, 1.5)).toDouble();

/// A stream plays outside Web Audio, so it gets quieter with distance by hand: the inverse model a
/// panner uses, times your music volume (`gain`).
double streamVolume(double gain, double distance) {
  final d = math.max(musicRef, distance);
  return math.min(1, gain * (musicRef / (musicRef + musicRolloff * (d - musicRef))));
}

// ---- Workers typing ----------------------------------------------------------------------------------

enum KeyKind { key, space, enter, mouse }

/// A worker typing at desk (x, z). `P` is whatever the sound engine hangs its panner on.
class Typist<P> {
  Typist(this.x, this.z);

  double x;
  double z;
  bool on = false;
  P? panner;

  /// When (audio clock) the next key lands.
  double next = 0;

  /// Keys left in this burst; 0 means a pause is running and the next key starts a new burst.
  int left = 0;

  /// Keys left in this word.
  int word = 0;

  /// Schedules its keys up to a little ahead of `now` on the audio clock, so the rhythm doesn't
  /// wobble with the frame rate.
  void schedule(double now, math.Random rng, void Function(double when, KeyKind kind) key) {
    double rand(double a, double b) => a + rng.nextDouble() * (b - a);
    int randInt(int a, int b) => rand(a.toDouble(), b + 1.0).floor();
    final horizon = now + 0.12;
    // Just started, or fell behind while the tab was hidden: begin again shortly.
    if (next < now - 0.25) {
      next = now + rand(0.05, 0.8);
      left = 0;
    }
    while (next < horizon) {
      final when = next;
      if (left == 0) {
        left = randInt(6, 36);
        word = randInt(2, 8);
        // Now and then they click around before typing again.
        if (rng.nextDouble() < 0.3) {
          key(when, KeyKind.mouse);
          if (rng.nextDouble() < 0.5) key(when + rand(0.1, 0.16), KeyKind.mouse);
          next = when + rand(0.4, 1.2);
          continue;
        }
      }
      left--;
      if (left == 0) {
        // End of a burst: often Enter, then a pause to read or think.
        key(when, rng.nextDouble() < 0.4 ? KeyKind.enter : KeyKind.key);
        next = when + (rng.nextDouble() < 0.15 ? rand(4, 9) : rand(0.6, 3));
      } else if (--word <= 0) {
        key(when, KeyKind.space);
        word = randInt(2, 8);
        next = when + rand(0.1, 0.22);
      } else {
        key(when, KeyKind.key);
        next = when + rand(0.065, 0.16);
      }
    }
  }
}
