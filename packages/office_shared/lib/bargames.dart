// The games in the rooftop bar's north-west corner: an axe-throwing lane and a dart board. You step
// up to the line (or the oche) and throw. Your page works out where it lands; the office passes that
// on to everyone else up there, and every page scores it the same way from here. Shared by the
// server (which checks a throw is one anyone could make) and the client.
// Ported from src/shared/bargames.ts.

import 'dart:math' as math;

import 'json_util.dart';
import 'layout.dart';

enum BarGame implements WireEnum {
  darts('darts'),
  axe('axe');

  const BarGame(this.wire);
  @override
  final String wire;

  static BarGame? tryParse(Object? v) => parseWireOrNull(values, v);
}

bool isBarGame(Object? v) => BarGame.tryParse(v) != null;

/// Throws in a round: a visit to the oche is three darts, a round at the lane five axes.
const Map<BarGame, int> barRound = {BarGame.darts: 3, BarGame.axe: 5};

/// The axe lane: a wooden booth in the corner, against the roof's north edge, open to the south. The
/// target hangs on its back wall facing into it (+z). [minX]..[maxX] is the lane between the side
/// walls ([wall] thick, [depth] out from the back, [height] tall, like the back wall). You throw from
/// behind the red line, [line] (twelve feet) from the target: one turn of the axe, done right.
abstract final class AxeLane {
  static const double minX = Floor.minX + 0.15;
  static const double maxX = Floor.minX + 2.95;
  static const double wall = 0.15;
  static const double depth = 3.4;
  static const double height = 2.6;

  /// The middle of the target's face.
  static const target = (x: Floor.minX + 1.55, y: 1.5, z: Floor.minZ + 0.25);
  static const double line = 3.66;
}

/// The dart board, on the outside of the axe lane's east wall, facing east (+x) over the deck. [oche]
/// is how far back the throwing line is from its face (seven feet nine and a quarter inches).
abstract final class Dartboard {
  static const double x = AxeLane.maxX + AxeLane.wall + 0.08;
  static const double y = 1.73;
  static const double z = Floor.minZ + 1.8;
  static const double oche = 2.37;
}

/// Where you stand to throw, just behind the line, and which way you face (a heading: 0 is +z,
/// turning toward +x). On the target, `u` runs to your right and `v` up, in meters from its middle.
({double x, double z, double facing}) throwSpot(BarGame game) {
  if (game == BarGame.darts) return (x: Dartboard.x + Dartboard.oche + 0.28, z: Dartboard.z, facing: -math.pi / 2);
  return (x: AxeLane.target.x, z: AxeLane.target.z + AxeLane.line + 0.3, facing: math.pi);
}

/// Where (u, v) on a game's target is: its middle, and which ways your right ([right]) and out of
/// its face toward you ([out]) are.
({double x, double y, double z, ({double x, double z}) right, ({double x, double z}) out}) targetFrame(BarGame game) {
  if (game == BarGame.darts) {
    return (x: Dartboard.x, y: Dartboard.y, z: Dartboard.z, right: (x: 0.0, z: -1.0), out: (x: 1.0, z: 0.0));
  }
  const t = AxeLane.target;
  return (x: t.x, y: t.y, z: t.z, right: (x: 1.0, z: 0.0), out: (x: 0.0, z: 1.0));
}

/// What a throw scores, and what the chalkboard says: "T20", "Bull", "Killshot", "Miss"…
typedef BarScore = ({int points, String label});

// ---- Darts ----------------------------------------------------------------------------------------

/// A regulation board, in meters out from the middle: the bull, the outer bull, the treble and
/// double rings, and the board itself (the ring of numbers round the outside scores nothing).
abstract final class DartRings {
  static const double bull = 0.00635;
  static const double outer = 0.0159;
  static const double trebleIn = 0.099;
  static const double trebleOut = 0.107;
  static const double doubleIn = 0.162;
  static const double doubleOut = 0.17;
  static const double board = 0.2255;
}

/// The numbers round the board, clockwise from the top.
const List<int> dartNumbers = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5];

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// What a dart at (u, v) on the board scores.
BarScore dartScore(double u, double v) {
  final r = _hypot(u, v);
  if (r <= DartRings.bull) return (points: 50, label: 'Bull');
  if (r <= DartRings.outer) return (points: 25, label: '25');
  if (r > DartRings.doubleOut) return (points: 0, label: r <= DartRings.board ? 'Out' : 'Miss');
  // Clockwise from straight up, each number's wedge centered on it.
  final a = math.atan2(u, v);
  final seg = (((a + math.pi / 20 + 2 * math.pi) % (2 * math.pi)) / (math.pi / 10)).floor() % 20;
  final n = dartNumbers[seg];
  if (r > DartRings.trebleIn && r <= DartRings.trebleOut) return (points: n * 3, label: 'T$n');
  if (r > DartRings.doubleIn) return (points: n * 2, label: 'D$n');
  return (points: n, label: '$n');
}

// ---- Axes -----------------------------------------------------------------------------------------

/// The axe target, painted on planks [width] by [height]: rings out from the bull, and a blue
/// killshot dot up in each top corner. [blade] is how long the axe's edge is: it scores wherever
/// along it is best, so an axe on a line takes the higher ring.
abstract final class AxeTarget {
  static const List<({double r, int points})> rings = [
    (r: 0.075, points: 6),
    (r: 0.17, points: 4),
    (r: 0.27, points: 3),
    (r: 0.37, points: 2),
    (r: 0.47, points: 1),
  ];
  static const kill = (u: 0.52, v: 0.55, r: 0.05, points: 8);
  static const double width = 1.5;
  static const double height = 1.9;
  static const double blade = 0.1;
}

/// Whether an axe hitting (u, v) is on the back wall, where it can stick: not the side walls, the
/// floor or over the top.
bool onBackWall(double u, double v) {
  const half = (AxeLane.maxX - AxeLane.minX) / 2 - 0.12;
  return u.abs() < half && v > 0.15 - AxeLane.target.y && v < AxeLane.height - 0.12 - AxeLane.target.y;
}

/// What an axe at (u, v) scores: nothing unless it [stuck] there.
BarScore axeScore(double u, double v, bool stuck) {
  if (!stuck) return (points: 0, label: 'Drop');
  const half = AxeTarget.blade / 2;
  // How far the edge (upright, `half` either side of v) comes to a point.
  double near(double pu, double pv) => _hypot(u - pu, math.max(0, (v - pv).abs() - half));
  const k = AxeTarget.kill;
  if (near(-k.u, k.v) <= k.r || near(k.u, k.v) <= k.r) return (points: k.points, label: 'Killshot');
  final r = near(0, 0);
  for (final ring in AxeTarget.rings) {
    if (r <= ring.r) return (points: ring.points, label: ring.points == 6 ? 'Bull' : '${ring.points}');
  }
  final board = u.abs() <= AxeTarget.width / 2 && v.abs() <= AxeTarget.height / 2;
  return (points: 0, label: board ? 'Board' : 'Wall');
}

/// What a throw scores, whichever the game.
BarScore barScore(BarGame game, double u, double v, bool stuck) =>
    game == BarGame.darts ? dartScore(u, v) : axeScore(u, v, stuck);

/// The most a round can score: three treble twenties, or five killshots.
const Map<BarGame, int> bestRound = {BarGame.darts: 180, BarGame.axe: 5 * 8};

// ---- Throwing ---------------------------------------------------------------------------------------

/// Drawing back runs a meter up and down; let go in its green (`at`, `width` wide) and a dart flies
/// true, an axe turns round just right to stick.
const Map<BarGame, ({double at, double width})> barGreen = {
  BarGame.darts: (at: 0.7, width: 0.12),
  BarGame.axe: (at: 0.66, width: 0.12),
};

/// How far past the green's edge (either way, as a part of the meter) an axe still turns near enough to stick.
const double _axeGrace = 0.015;

/// The meter [secs] into drawing back: up to full over [period], back down, and up again.
double meterAt(double secs, double period) {
  final p = (secs / period) % 2;
  return p > 1 ? 2 - p : p;
}

/// A throw: which game, where on the target (u, v), whether an axe stuck there, and which throw of
/// the round it is (from 1).
class Toss {
  const Toss({required this.game, required this.u, required this.v, required this.stick, required this.n});

  final BarGame game;
  final double u;
  final double v;
  final bool stick;
  final int n;

  Map<String, dynamic> toJson() => {'game': game.wire, 'u': u, 'v': v, 'stick': stick, 'n': n};
}

/// Where a throw aimed at (u, v) goes for how hard it was thrown ([power], 0–1 on the meter). How far
/// off the green that is sends a dart low or high (only a little inside it), and an axe that's off it
/// doesn't come round right to stick. [jitter] (−1 to 1 each way) is the hand's own little miss.
({BarGame game, double u, double v, bool stick}) landing(
  BarGame game,
  double u,
  double v,
  double power, [
  (double, double) jitter = (0, 0),
]) {
  final g = barGreen[game]!;
  final off = power - g.at;
  final half = g.width / 2;
  if (game == BarGame.darts) {
    final drop = off.abs() <= half ? off * 0.25 : off.sign * (half * 0.25 + (off.abs() - half) * 1.1);
    return (game: game, u: u + jitter.$1 * 0.006, v: v + drop + jitter.$2 * 0.006, stick: true);
  }
  final lu = u + jitter.$1 * 0.02;
  final lv = v + off * 0.35 + jitter.$2 * 0.02;
  return (game: game, u: lu, v: lv, stick: off.abs() <= half + _axeGrace && onBackWall(lu, lv));
}

/// Whether a throw from a page is one the office passes on: somewhere near the target, and a throw of
/// the round.
bool tossOk({required Object? game, required Object? u, required Object? v, required Object? n}) {
  final g = BarGame.tryParse(game);
  if (g == null) return false;
  if (u is! num || v is! num || !u.isFinite || !v.isFinite) return false;
  if (n is! num || !n.isFinite || n != n.truncate() || n < 1 || n > barRound[g]!) return false;
  return u.abs() <= 3 && v.abs() <= 3;
}
