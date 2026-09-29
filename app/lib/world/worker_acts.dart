// What a worker's body is doing, as numbers: the stances it acts out its latest tool call with
// (world/character.ts's Act / Stance / stanceOf), how it blends from one to the next, and the
// timeline of the dance it does on its desk when a pull request merges. Kept apart from the models
// so it can be tested without a scene.

import 'dart:math' as math;

import 'package:office_shared/protocol.dart' show WorkerAction, WorkerStatus;

/// What a worker's body is doing: resting, arms up for joy, arms crossed waiting on you, typing, or
/// acting out its latest tool call.
enum Act { rest, up, waiting, type, read, edit, test, web, failing }

Act actOf(WorkerAction a) => switch (a) {
  WorkerAction.read => Act.read,
  WorkerAction.edit => Act.edit,
  WorkerAction.test => Act.test,
  WorkerAction.web => Act.web,
  WorkerAction.failing => Act.failing,
};

/// What it acts out, from its status and latest tool call: up for joy while it hops (or is done and
/// bouncing), waiting on you, its action (or typing) while working, else resting.
Act pickAct({required WorkerStatus status, required bool hopping, required bool bouncing, WorkerAction? action}) {
  if (hopping || (bouncing && status == WorkerStatus.done)) return Act.up;
  if (status == WorkerStatus.needsInput) return Act.waiting;
  if (status == WorkerStatus.working) return action == null ? Act.type : actOf(action);
  return Act.rest;
}

/// One way of holding itself, blended into the next over a moment (see [StanceBlend]).
class Stance {
  /// Arms swung forward (x below 0 reaches toward the desk, -2.6 is straight up) and in toward the
  /// middle (z). The left arm is the one on -x.
  double armLx = -0.3, armRx = -0.3, armLz = 0, armRz = 0;

  /// 0..1: shoulders brought forward and in, for arms that wrap round the front (crossed, or holding its head).
  double reach = 0;

  /// Shoulders lowered, so crossed arms sit on its belly and not under its eyes.
  double drop = 0;

  /// Leaning toward the desk (+) or back (-), turned, tipped to the side, bobbing up.
  double lean = 0, turn = 0, roll = 0, lift = 0;

  /// How far its right foot is lifted, tapping, and both feet stretched out in front.
  double tap = 0, kick = 0;

  /// Eyes open (1) or narrowed, and looking up (+) or down (-).
  double lid = 1, look = 0;

  List<double> get values => [armLx, armRx, armLz, armRz, reach, drop, lean, turn, roll, lift, tap, kick, lid, look];

  set values(List<double> v) {
    armLx = v[0];
    armRx = v[1];
    armLz = v[2];
    armRz = v[3];
    reach = v[4];
    drop = v[5];
    lean = v[6];
    turn = v[7];
    roll = v[8];
    lift = v[9];
    tap = v[10];
    kick = v[11];
    lid = v[12];
    look = v[13];
  }
}

/// The stance for [act] at [t] seconds.
Stance stanceOf(Act act, double t, [Stance? into]) {
  final s = into ?? Stance();
  s.armLx = s.armRx = -0.3;
  s.armLz = s.armRz = s.reach = s.drop = s.lean = s.turn = s.roll = s.tap = s.kick = s.look = 0;
  s.lift = math.sin(t * 2) * 0.015;
  s.lid = 1;
  switch (act) {
    case Act.rest:
      break;
    case Act.up:
      s.armLx = s.armRx = -2.6;
      s.lift = 0;
    case Act.type:
      s.armLx = -1.2 + math.sin(t * 22) * 0.25;
      s.armRx = -1.2 + math.sin(t * 22 + 1.7) * 0.25;
      s.lift = math.sin(t * 11).abs() * 0.02;
    case Act.edit:
      // Hunched over the keys, typing flat out.
      s.armLx = -1.25 + math.sin(t * 34) * 0.34;
      s.armRx = -1.25 + math.sin(t * 34 + 1.9) * 0.34;
      s.lean = 0.16;
      s.lift = math.sin(t * 17).abs() * 0.035;
      s.look = -0.02;
    case Act.read:
      // The papers held up in front, eyes running down the page.
      s.armLx = s.armRx = -2.05;
      s.armLz = 0.3;
      s.armRz = -0.3;
      s.lean = -0.06;
      s.look = -0.01 - ((t * 0.9) % 1) * 0.03;
    case Act.test:
      // Leaning back, hands behind its head, feet out: waiting on the run.
      s.armLx = s.armRx = -3.3;
      s.armLz = 0.55;
      s.armRz = -0.55;
      s.lean = -0.32;
      s.roll = math.sin(t * 1.3) * 0.04;
      s.kick = 0.08;
      s.look = 0.025;
      s.lift = 0;
    case Act.web:
      // Scrolling with one hand, looking up at the globe.
      s.armLx = -1.2 + math.sin(t * 9) * 0.15;
      s.armRx = -0.8;
      s.lean = -0.1;
      s.look = 0.03;
    case Act.failing:
      // Head in its hands, shaking it slowly.
      s.armLx = s.armRx = -2;
      s.armLz = 0.45;
      s.armRz = -0.45;
      s.reach = 1;
      s.lean = 0.38;
      s.turn = math.sin(t * 2.4) * 0.16;
      s.lid = 0.55;
      s.look = -0.035;
      s.lift = 0;
    case Act.waiting:
      // Arms crossed, hip cocked, tapping a foot.
      final tap = math.max(0.0, math.sin(t * 16));
      s.armLx = -1.05;
      s.armRx = -1.2;
      s.armLz = 1;
      s.armRz = -1;
      s.reach = 1;
      s.drop = 0.11;
      s.roll = 0.07;
      s.tap = tap;
      s.lift = tap * 0.012;
      s.lid = 0.6;
  }
  return s;
}

/// How long a worker keeps acting something out before the next thing, so quick tool calls don't flicker.
const double kActMin = 1.2;

/// Head in its hands lasts at least this long, so you catch it.
const double kDespairMin = 4;

/// Waiting on you: it jumps this long (seconds), then taps its foot with its arms crossed until the cycle comes round.
const double kWaitHops = 2;
const double kWaitCycle = 4.6;

/// A full spin when it finishes, this long.
const double kTwirlTime = 0.9;

double easeInOut(double x) => x * x * (3 - 2 * x);

/// 0 → 1 with a little overshoot, for props popping in.
double popIn(double x) => x <= 0
    ? 0
    : x >= 1
    ? 1
    : 1 + 2.7 * math.pow(x - 1, 3) + 1.7 * math.pow(x - 1, 2);

/// The latest tool call, held on to for a moment before the next one takes over (see [kActMin]).
class ActionTimer {
  WorkerAction? next;
  WorkerAction? current;
  double _t = 0;

  /// Moves on [dt] seconds; returns what to act out now.
  WorkerAction? step(double dt) {
    _t += dt;
    if (next != current && _t >= (current == WorkerAction.failing ? kDespairMin : kActMin)) {
      current = next;
      _t = 0;
    }
    return current;
  }
}

/// How much of each act is in a worker's stance right now, blending from one to the next.
class StanceBlend {
  final Map<Act, double> weights = {};
  final Stance _scratch = Stance();
  final Stance out = Stance();

  /// How much of [act] is in the stance right now.
  double weight(Act act) => weights[act] ?? 0;

  /// Eases toward [act]'s stance, out of whatever it was doing before.
  Stance pose(Act act, double dt, double t) {
    final k = math.min(1.0, dt * 8);
    weights.putIfAbsent(act, () => 0);
    final sum = List<double>.filled(14, 0);
    var total = 0.0;
    for (final a in weights.keys.toList()) {
      final w0 = weights[a]!;
      final w = w0 + ((a == act ? 1 : 0) - w0) * k;
      if (a != act && w < 0.01) {
        weights.remove(a);
        continue;
      }
      weights[a] = w;
      final v = stanceOf(a, t, _scratch).values;
      for (var i = 0; i < 14; i++) {
        sum[i] += v[i] * w;
      }
      total += w;
    }
    if (total <= 0) {
      // Just started, with nothing in it yet: straight into the act.
      out.values = stanceOf(act, t, _scratch).values;
      weights[act] = k;
      return out;
    }
    out.values = [for (final v in sum) v / total];
    return out;
  }
}

// ---- The dance party ----------------------------------------------------------------------------

/// Seconds a beat: a quick 140 to the minute.
const double kBeat = 60 / 140;

/// A dance's parts, in seconds: the hop up on to the desk, eight beats of moves, the hop back down.
const double kDanceUp = 0.5, kDanceMoves = 8 * kBeat, kDanceDown = 0.5;
const double kDanceTime = kDanceUp + kDanceMoves + kDanceDown;

/// How high a hop between the seat and the desk goes, over the straight line.
const double kHop = 0.5;

/// Where a dance is at [t] seconds in: how far from the seat (0) to the stage (1) and the hop's arc
/// over that, and the moves: arms (left, right) and the body's lift, sway, twist and step.
typedef DanceMoves = ({
  double on,
  double arc,
  double beat,
  List<double> armX,
  List<double> armZ,
  double lift,
  double sway,
  double twist,
  double step,
});

DanceMoves danceAt(double t) {
  var on = 1.0;
  var arc = 0.0;
  if (t < kDanceUp || t > kDanceUp + kDanceMoves) {
    final u = (t < kDanceUp ? t / kDanceUp : 1 - (t - kDanceUp - kDanceMoves) / kDanceDown).clamp(0.0, 1.0);
    on = u;
    arc = 4 * kHop * u * (1 - u);
  }
  var armX = [-2.6, -2.6];
  var armZ = [0.0, 0.0];
  var lift = 0.0, sway = 0.0, twist = 0.0, step = 0.0;
  final beat = on < 1 ? -1.0 : (t - kDanceUp) / kBeat;
  if (beat >= 0 && beat < 4) {
    // Groove: a bounce on every beat, swaying side to side, raising the roof one arm at a time.
    final s = math.sin(beat * math.pi);
    final c = math.cos(beat * math.pi);
    lift = s.abs() * 0.12;
    sway = s * 0.22;
    twist = s * 0.3;
    step = s;
    armX = [-1.6 - c * 1.2, -1.6 + c * 1.2];
    armZ = [-0.35, 0.35];
  } else if (beat >= 4 && beat < 6) {
    // A twirl on the spot, arms out wide.
    final u = (beat - 4) / 2;
    twist = easeInOut(u) * math.pi * 2;
    lift = math.sin(u * math.pi) * 0.18;
    armX = [-0.3, -0.3];
    armZ = [-1.35, 1.35];
  } else if (beat >= 6) {
    // Two big jumps, arms up.
    lift = math.sin((beat - 6) * math.pi).abs() * 0.45;
    armZ = [-0.3, 0.3];
  }
  return (on: on, arc: arc, beat: beat, armX: armX, armZ: armZ, lift: lift, sway: sway, twist: twist, step: step);
}

/// Asked to dance again at [t] seconds into a dance: it stays up there (or goes back up from
/// wherever it is on the way down) and dances on.
double danceAgain(double t) {
  if (t > kDanceUp + kDanceMoves) return kDanceUp * (1 - (t - kDanceUp - kDanceMoves) / kDanceDown);
  return math.min(t, kDanceUp);
}
