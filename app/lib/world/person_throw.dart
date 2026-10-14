// Throwing darts (with the right hand, the arm on -x) and axes (both hands, over the head), from
// world/character/person-throw.ts. A dart is held up by the eye, drawn back as far as the wind-up takes
// it, and pushed out at the board. An axe goes round on an arc about [_axeTurn], from in front of the
// chest (`aim`) back over the head, and over and down in front to throw, let go of on the way
// (`release`). Its handle points out along the arc, tipped back [_axeWrist] from it. Seconds for each:
// the throw, and a whole one on its own (someone else's) taking it back first. The next dart or axe is
// in hand `reload` after letting go.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/bargames.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'geo.dart';

final vm.Vector3 _dartAim = vm.Vector3(-0.2, 1.45, 0.36);
final vm.Vector3 _dartBack = vm.Vector3(-0.21, 1.5, 0.12);
final vm.Vector3 _dartOut = vm.Vector3(-0.24, 1.25, 0.6);
final vm.Vector3 _axeTurn = vm.Vector3(0, 1.05, 0.02);
const _axeArc = (r: 0.36, aim: 0.25, back: 2.2, release: 0.55, end: -0.5);
const double _axeWrist = 1.15;
const Map<BarGame, ({double time, double release, double auto, double reload})> _throw = {
  BarGame.darts: (time: 0.16, release: 0.5, auto: 0.25, reload: 0.55),
  BarGame.axe: (time: 0.28, release: 0.62, auto: 0.35, reload: 1.2),
};
final vm.Vector3 _down = vm.Vector3(0, -1, 0);

/// Where a thrown dart or axe leaves the hand ([from], in the space the people stand in) and, for an
/// axe, how far it's turned over its handle.
typedef Release = void Function(vm.Vector3 from, double turn);

/// The dart or axe in hand, and the throw it's in (see the Person's `oche`).
class Oche {
  Oche(this.game, this.prop);
  final BarGame game;
  final Node prop;
  double back = 0;
  double want = 0;
  double top = 0;
  double throwT = -1;
  double autoT = -1;
  double reload = 0;

  /// The prop's turn over its handle (its rotation.x), for an axe let go of.
  double turn = 0;
  Release? release;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

vm.Vector3 _lerpV(vm.Vector3 a, vm.Vector3 b, double t) => a + (b - a) * t;

/// Where the hands are round the axe's arc at elevation [phi].
vm.Vector3 _axeHands(double phi) =>
    vm.Vector3(_axeTurn.x, _axeTurn.y + math.sin(phi) * _axeArc.r, _axeTurn.z + math.cos(phi) * _axeArc.r);

/// The throwing arm (or arms), and the dart or axe in hand, over whatever they were doing. [armL] and
/// [armR] are the arms' pivots (at x -0.33 and 0.33, 0.9 up the body), [body] the body's; [propAt]
/// says where the prop is in the space the people stand in, for letting go of it.
void throwStep(Oche o, Pivot armL, Pivot armR, Pivot body, double dt, vm.Vector3 Function() propAt) {
  final t = _throw[o.game]!;
  if (o.autoT >= 0) {
    o.autoT += dt;
    o.want = math.min(1, o.autoT / t.auto);
    o.back += (o.want - o.back) * math.min(1, dt * 14);
    if (o.autoT >= t.auto) {
      o.autoT = -1;
      o.top = o.back;
      o.throwT = 0;
    }
  } else if (o.throwT < 0) {
    o.back += (o.want - o.back) * math.min(1, dt * 14);
  }
  // How far through the throw: 0 drawn back, 1 all the way out, easing back to aiming after.
  var out = -1.0;
  if (o.throwT >= 0) {
    o.throwT += dt;
    final u = o.throwT / t.time;
    if (u < 1) {
      out = u * u;
    } else if (u < 2.5) {
      out = 1;
    } else {
      out = -1;
      o.throwT = -1;
      o.back = o.want = 0;
    }
  }
  if (o.reload > 0) {
    o.reload -= dt;
    if (o.reload <= 0) o.prop.visible = true;
  }
  final prop = o.prop;
  void rest(Pivot arm, double sx, vm.Vector3 at) {
    final dir = vm.Vector3(at.x - sx, at.y - 0.9, at.z)..normalize();
    arm.turn = vm.Quaternion.fromTwoVectors(_down, dir);
  }

  if (o.game == BarGame.darts) {
    final at = out >= 0
        ? _lerpV(_lerpV(_dartAim, _dartBack, o.top), _dartOut, out)
        : _lerpV(_dartAim, _dartBack, o.back);
    rest(armL, -0.33, at);
    // The dart's held by the barrel in the fist, at the end of the arm, pointing out and a little up.
    final dir = vm.Vector3(at.x + 0.33, at.y - 0.9, at.z)..normalize();
    prop.position = vm.Vector3(-0.33, 0.9, 0) + dir * 0.38 + vm.Vector3(0, 0, 0.09);
    o.turn = -0.12;
    prop.rotation = euler(-0.12, 0, 0);
  } else {
    final phi = out >= 0
        ? _lerp(_lerp(_axeArc.aim, _axeArc.back, o.top), _axeArc.end, out)
        : _lerp(_axeArc.aim, _axeArc.back, o.back);
    final at = _axeHands(phi);
    rest(armL, -0.33, vm.Vector3(at.x - 0.03, at.y + 0.03, at.z));
    rest(armR, 0.33, vm.Vector3(at.x + 0.03, at.y - 0.05, at.z));
    prop.position = at;
    o.turn = math.pi / 2 - phi - _axeWrist;
    prop.rotation = euler(o.turn, 0, 0);
    // Leaning into it, down the lane.
    body.x = out >= 0 ? math.sin(math.min(1.0, out) * math.pi) * 0.18 : -o.back * 0.1;
  }
  final released = out >= 0 && out >= t.release * t.release;
  final release = o.release;
  if (released && release != null) {
    o.release = null;
    release(propAt(), o.turn);
    prop.visible = false;
    o.reload = t.reload;
  }
}
