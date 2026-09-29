// Getting between the floors without the elevator (a port of climb.ts): up and down the ladder by
// the west wall, and down a fire pole. Either one takes hold of you (PlayerController.rig) until
// you're off it again. Pure logic, no GPU: tested in test/world/climb_test.dart.

import 'dart:math' as math;

import 'package:office_shared/layout.dart';

import 'player.dart';

/// Up to the floor above (+1) or down to the one below (-1).
typedef Way = int;

/// What you're holding on to.
enum Grip { ladder, pole }

/// How fast you go up and down the ladder, in meters a second.
const double _climb = 1.9;

/// Up this far on the ladder your head's through the hatch: on up to the floor above.
const double ladderTop = wallHeight - 1.15;

/// Down this far you're through the floor (your eyes just under it): on down to the floor below.
const double ladderBottom = -1.5;

/// Where you stand once you're off the ladder: on the floor in front of its hatch.
final double offLadderX = Ladder.hatch.maxX + 0.4;

/// Stepping off takes this long, in seconds.
const double _stepOff = 0.45;

/// Down a pole's hole this far, your eyes go under the floor: on to the floor below.
const double poleBottom = -1.5;

/// Sliding down: gravity, less what your hands take off it.
const double _slideG = 12;
const double slideMax = 6.5;

/// How fast you come out of the ceiling onto the floor below: the dark in between takes some of it off.
const double _slideIn = 3.5;

/// A twirl round a pole that doesn't go anywhere (on the bottom floor).
const double _twirl = 1.15;

/// Swinging off a pole onto a floor it goes on down through: how long, and how far out from it you end up (past the railing).
const double _swingOff = 0.55;
const double offPole = Pole.rail + 0.4;

/// Where you arrive on the other floor: the same spot in the office, on the other side of the ceiling.
typedef Arrival = ({double x, double y, double z, double rotY});

/// What a climb asks of the office.
class ClimbHooks {
  ClimbHooks({required this.floorThere, required this.travel, required this.sound, required this.done});

  /// The name of the floor that way, if there's one.
  final String? Function(Way way) floorThere;

  /// Go there, arriving at `at`; [Climber.arrived] or [Climber.abort] follows.
  final void Function(Way way, Grip how, Arrival at) travel;

  /// Something to hear: 'grab', 'rung', 'slide', 'land' (how fast), 'bonk' (the top of the ladder), 'twirl'.
  final void Function(String kind, double speed) sound;

  /// You're off the ladder or the pole, back on your feet.
  final void Function(Grip how, bool landed) done;
}

enum _PoleStage { hop, slide, wait, twirl, off }

class _StepOff {
  _StepOff(this.x, this.y, this.yaw, this.toYaw, this.facing);
  double t = 0;
  final double x, y, yaw, toYaw, facing;
}

sealed class _State {}

class _OnLadder extends _State {
  _OnLadder(this.rung);

  /// Carrying on by itself the rest of the way, after a floor change: up (1) or down (-1) to the floor.
  int auto = 0;

  /// Waiting on the floor you're going to (the lights are down).
  bool waiting = false;

  /// The rung your hands were on last, for its clank.
  int rung;

  /// Stepping off: seconds in, from where, and which way you end up facing.
  _StepOff? off;
  bool bonked = false;
}

class _OnPole extends _State {
  _OnPole(this.spot, this.stage, this.angle, this.fromX, this.fromY, this.fromZ);

  final PoleSpot spot;
  _PoleStage stage;

  /// Where you are round the pole (0 = +z of it) and how fast you're going down.
  double angle;
  double v = 0;
  double t = 0;
  final double fromX, fromY, fromZ;

  /// Come down through the ceiling onto the floor below: the next stop is the mat, or off the pole beside its hole.
  bool through = false;

  /// Swinging off: where round the pole you started from.
  double? offFrom;
}

double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));
double _lerp(double a, double b, double t) => a + (b - a) * t;

/// You, on the ladder or a pole.
class Climber {
  Climber(this.player, this.hooks);

  final PlayerController player;
  final ClimbHooks hooks;
  _State? _state;

  /// How fast you're sliding, 0–1, for the speed lines and the wider view.
  double rush = 0;

  bool get active => _state != null;

  Grip? get grip => switch (_state) {
    _OnLadder() => Grip.ladder,
    _OnPole() => Grip.pole,
    null => null,
  };

  /// On the ladder, and where: how far up it you are, and whether you're between floors or carried along.
  ({double y, bool waiting, bool auto})? get ladder {
    final s = _state;
    return s is _OnLadder ? (y: player.pos.y, waiting: s.waiting, auto: s.auto != 0 || s.off != null) : null;
  }

  /// Sliding (or twirling) down a pole: 'slide' or 'twirl'.
  String? get sliding {
    final s = _state;
    return s is _OnPole ? (s.stage == _PoleStage.twirl ? 'twirl' : 'slide') : null;
  }

  /// Takes hold of the ladder, from the floor in front of it or wherever you are up it.
  void grabLadder() {
    if (_state != null) return;
    final p = player;
    p.pos.y = p.pos.y.clamp(0, ladderTop);
    _state = _OnLadder((p.pos.y / 0.3).round());
    p.facing = -math.pi / 2;
    if (p.view == ViewMode.first) {
      // Face the rungs, looking up them.
      p.camYaw = math.pi / 2;
      p.lookPitch = 0.45;
    }
    p.moving = false;
    p.rig = _ladderStep;
    hooks.sound('grab', 0);
  }

  /// Grabs the pole and slides down it, through its hole to the floor below.
  void slide(PoleSpot spot) {
    if (_state != null) return;
    final p = player;
    final angle = math.atan2(p.pos.x - spot.x, p.pos.z - spot.z);
    _state = _OnPole(spot, _PoleStage.hop, angle, p.pos.x, p.pos.y, p.pos.z);
    p.moving = false;
    p.rig = _poleStep;
    hooks.sound('grab', 0);
  }

  /// Swings once round a pole that goes nowhere from here (the bottom floor's).
  void twirl(PoleSpot spot) {
    if (_state != null) return;
    final p = player;
    final angle = math.atan2(p.pos.x - spot.x, p.pos.z - spot.z);
    _state = _OnPole(spot, _PoleStage.twirl, angle, p.pos.x, p.pos.y, p.pos.z);
    p.rig = _poleStep;
    hooks.sound('twirl', 0);
  }

  /// E on the ladder: off it at the floor, or let go and drop from wherever you are.
  void letGo() {
    final s = _state;
    if (s is! _OnLadder || s.waiting || s.auto != 0 || s.off != null) return;
    final p = player;
    if (p.pos.y < -0.05) return; // down the hatch: nothing to land on but the next floor
    if (p.pos.y < 0.4) {
      _stepOffLadder(s);
      return;
    }
    // Drop off it: a little way out from the wall, and down you go.
    p.pos.x = Ladder.x + 0.3;
    _release(Grip.ladder, false);
  }

  /// Now on the floor you were going to: carry on the rest of the way.
  void arrived() {
    final s = _state;
    final p = player;
    if (s is _OnLadder && s.waiting) {
      // Your head was up in the hatch (or your feet down the one below): now that's this floor's.
      final way = p.pos.y > 1 ? 1 : -1;
      p.pos.y += way > 0 ? -storey : storey;
      s.waiting = false;
      s.auto = way;
      s.rung = (p.pos.y / 0.3).round();
    } else if (s is _OnPole && s.stage == _PoleStage.wait) {
      p.pos.y += storey;
      s.stage = _PoleStage.slide;
      s.through = true;
      s.v = math.min(s.v, _slideIn);
    }
  }

  /// The other floor never came: back onto this one's floor, off whatever you were on.
  void abort() {
    final s = _state;
    if (s == null) return;
    final p = player;
    switch (s) {
      case _OnLadder():
        p.pos.setValues(offLadderX, 0, Ladder.z);
        _release(Grip.ladder, false);
      case _OnPole():
        p.pos.setValues(s.fromX, 0, s.fromZ);
        _release(Grip.pole, false);
    }
  }

  void _release(Grip how, bool landed) {
    _state = null;
    rush = 0;
    final p = player;
    p.rig = null;
    p.moving = false;
    p.vy = 0;
    hooks.done(how, landed);
  }

  void _stepOffLadder(_OnLadder s) {
    final p = player;
    // Back off the ladder and turn round to the room.
    const toYaw = -math.pi / 2;
    final yaw = toYaw + _wrap(p.camYaw - toYaw);
    s.off = _StepOff(p.pos.x, p.pos.y, yaw, toYaw, math.pi / 2);
    s.auto = 0;
  }

  void _ladderStep(double dt) {
    final s = _state;
    if (s is! _OnLadder) return;
    final p = player;
    final off = s.off;
    if (off != null) {
      off.t += dt;
      final k = math.min(1.0, off.t / _stepOff);
      final e = k * k * (3 - 2 * k);
      p.pos.x = _lerp(off.x, offLadderX, e);
      p.pos.y = _lerp(off.y, 0, e) + math.sin(math.pi * k) * 0.12;
      p.pos.z += (Ladder.z - p.pos.z) * math.min(1, dt * 12);
      p.facing = _lerp(-math.pi / 2, off.facing, e);
      if (p.view == ViewMode.first) {
        p.camYaw = _lerp(off.yaw, off.toYaw, e);
        p.lookPitch += (-0.08 - p.lookPitch) * math.min(1, dt * 8);
      }
      p.moving = k < 1;
      if (k >= 1) {
        p.pos.y = 0;
        _release(Grip.ladder, true);
      }
      return;
    }
    // Onto the rungs, facing the wall.
    p.pos.x += (Ladder.x - p.pos.x) * math.min(1, dt * 12);
    p.pos.z += (Ladder.z - p.pos.z) * math.min(1, dt * 12);
    p.facing = -math.pi / 2;
    if (s.auto == 0 && !s.waiting && p.pos.y >= 0 && p.holding(jump: true)) {
      // Jump off, back from the wall.
      p.pos.x = Ladder.x + 0.3;
      _release(Grip.ladder, false);
      p.vy = 3.5;
      return;
    }
    final int dir;
    if (s.waiting) {
      dir = 0;
    } else if (s.auto != 0) {
      dir = s.auto;
    } else {
      dir = (p.holding(up: true) ? 1 : 0) - (p.holding(down: true) ? 1 : 0);
    }
    final up = hooks.floorThere(1);
    final down = hooks.floorThere(-1);
    var y = p.pos.y + dir * _climb * dt;
    // At the floor: off, unless you're on your way down through it.
    if (dir < 0 && y <= 0 && p.pos.y >= 0 && (s.auto == -1 || down == null)) {
      p.pos.y = 0;
      _stepOffLadder(s);
      return;
    }
    // Climbing up out of the hatch onto a new floor: step off onto it.
    if (dir > 0 && s.auto == 1 && y >= 0) {
      p.pos.y = 0;
      _stepOffLadder(s);
      return;
    }
    if (dir > 0 && y > ladderTop) {
      y = ladderTop;
      if (up == null) {
        if (!s.bonked) hooks.sound('bonk', 0);
        s.bonked = true;
      } else {
        _go(s, 1, y);
      }
    } else if (dir < 0) {
      s.bonked = false;
    }
    if (dir < 0 && y < ladderBottom) {
      y = ladderBottom;
      _go(s, -1, y);
    }
    p.pos.y = y;
    p.moving = dir != 0 && !s.waiting;
    p.walkPhase += dir.abs() * dt * 7;
    final rung = (y / 0.3).round();
    if (rung != s.rung) {
      s.rung = rung;
      hooks.sound('rung', 0);
    }
  }

  void _go(_OnLadder s, Way way, double y) {
    if (s.waiting) return;
    s.waiting = true;
    final p = player;
    hooks.travel(way, Grip.ladder, (x: p.pos.x, y: y + (way > 0 ? -storey : storey), z: p.pos.z, rotY: p.facing));
  }

  void _poleStep(double dt) {
    final s = _state;
    if (s is! _OnPole) return;
    final p = player;
    final spot = s.spot;
    s.t += dt;
    void place(double r) {
      p.pos.x = spot.x + math.sin(s.angle) * r;
      p.pos.z = spot.z + math.cos(s.angle) * r;
    }

    final r0 = math.sqrt(math.pow(s.fromX - spot.x, 2) + math.pow(s.fromZ - spot.z, 2));
    switch (s.stage) {
      case _PoleStage.twirl:
        final k = math.min(1.0, s.t / _twirl);
        s.angle += dt * (math.pi * 2 / _twirl) * math.sin(math.pi * k) * 1.57;
        final r = _lerp(r0, Pole.grip + 0.1, math.sin(math.pi * k));
        place(math.max(r, Pole.grip));
        p.pos.y = s.fromY + math.sin(math.pi * k) * 0.5;
        _face(s.angle, dt, 0.1);
        p.moving = false;
        if (k >= 1) {
          p.pos.y = s.fromY;
          _release(Grip.pole, false);
        }
        return;
      case _PoleStage.hop:
        // A hop onto the pole: in to it, and up a little.
        final k = math.min(1.0, s.t / 0.28);
        place(_lerp(r0, Pole.grip, k));
        p.pos.y = s.fromY + math.sin(math.pi * k * 0.5) * 0.35;
        _face(s.angle, dt, 0);
        if (k >= 1) {
          s.stage = _PoleStage.slide;
          hooks.sound('slide', 0);
        }
        return;
      case _PoleStage.wait:
        // In the dark under the floor, holding on, while the floor below comes.
        _face(s.angle, dt, -0.4);
        return;
      case _PoleStage.off:
        // Round to the railing's gap, then out through it onto the floor with a little hop.
        final k = math.min(1.0, s.t / _swingOff);
        double ease(double x) => x * x * (3 - 2 * x);
        final turn = ease(math.min(1, k / 0.6));
        final out = ease(math.max(0, (k - 0.4) / 0.6));
        final a0 = s.offFrom ?? s.angle;
        s.angle = a0 + _wrap(spot.open - a0) * turn;
        place(_lerp(Pole.grip, offPole, out));
        p.pos.y = math.sin(math.pi * k) * 0.25;
        // From facing round the pole to facing out, away from it.
        final along = s.angle + math.pi / 2;
        p.facing = along + _wrap(spot.open - along) * out;
        if (p.view == ViewMode.first) {
          final yaw = p.facing - math.pi;
          p.camYaw += _wrap(yaw - p.camYaw) * math.min(1, dt * 10);
          p.lookPitch += (-0.08 - p.lookPitch) * math.min(1, dt * 8);
        }
        p.moving = out > 0 && k < 1;
        rush = math.max(0, rush - dt * 4);
        if (k >= 1) {
          p.pos.y = 0;
          hooks.sound('land', s.v);
          _release(Grip.pole, true);
        }
        return;
      case _PoleStage.slide:
        break;
    }
    // Down you go, faster and faster, spinning round the pole; squeeze to slow down near the bottom.
    final braking = s.through && p.pos.y < 1;
    if (braking) {
      s.v = math.max(2, s.v - 26 * dt);
    } else {
      s.v = math.min(slideMax, s.v + _slideG * dt);
    }
    s.angle += dt * (1.6 + s.v * 0.55);
    place(Pole.grip);
    p.pos.y -= s.v * dt;
    rush = math.min(1, s.v / slideMax);
    _face(s.angle, dt, braking ? -0.12 : -0.4);
    p.moving = false;
    p.walkPhase += dt * 4;
    if (p.pos.y <= poleBottom && !s.through) {
      p.pos.y = poleBottom;
      s.stage = _PoleStage.wait;
      hooks.travel(-1, Grip.pole, (x: p.pos.x, y: poleBottom + storey, z: p.pos.z, rotY: p.facing));
      return;
    }
    if (p.pos.y <= 0 && s.through) {
      p.pos.y = 0;
      if (hooks.floorThere(-1) != null) {
        // No mat here: the pole goes on down through a hole in this floor. Off it, beside the hole.
        s.stage = _PoleStage.off;
        s.t = 0;
        s.offFrom = s.angle;
        return;
      }
      final speed = s.v;
      // Knees bend as you land.
      p.stepOffset = -0.35;
      hooks.sound('land', speed);
      _release(Grip.pole, true);
    }
  }

  /// Swinging round the pole: you face the way you're going, the pole on your left. In first person
  /// you look a little toward it (so it's in view, hands on it) and down a little.
  void _face(double angle, double dt, double pitch) {
    final p = player;
    final facing = angle + math.pi / 2;
    p.facing = facing;
    if (p.view != ViewMode.first) return;
    final yaw = facing + 1.25 - math.pi;
    p.camYaw += _wrap(yaw - p.camYaw) * math.min(1, dt * 10);
    p.lookPitch += (pitch - p.lookPitch) * math.min(1, dt * 6);
  }
}

/// Whether someone at (x, y, z) is holding on to the ladder or a pole (someone else, going by where
/// they are): up off the floor ([ground]), right where your hands would be.
Grip? gripOf(double x, double y, double z, List<PoleSpot> poles, double ground) {
  if ((y - ground).abs() < 0.05) return null;
  if ((x - Ladder.x).abs() < 0.12 && (z - Ladder.z).abs() < 0.15) return Grip.ladder;
  for (final s in poles) {
    if ((math.sqrt(math.pow(x - s.x, 2) + math.pow(z - s.z, 2)) - Pole.grip).abs() < 0.12) return Grip.pole;
  }
  return null;
}
