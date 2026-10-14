// Stepping up to the dart board's oche or the axe lane's line, up on the roof (E there;
// features/bargames/controller.ts): you stand at the line with a dart (or an axe) in hand, and the camera
// looks over your shoulder at the target. The mouse (or the arrow keys) moves where you aim, which
// wanders a little with your hand, and more after a few drinks. Holding Space (or the mouse button)
// draws it back while the meter runs up and down; let go to throw. In the green a dart flies true and
// an axe turns just right to stick. Too soft and a dart drops, too hard and it sails high; either way
// an axe comes in wrong and bounces off. E steps back from the line.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:office_shared/bargames.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../world/person_throw.dart' show Release;
import '../world/space.dart';

/// How each game feels: the meter's period, how far your aim wanders (sober) and how quickly, how far
/// you can aim from the target's middle and how fast the keys move it, meters of aim a pixel of the
/// captured mouse, the camera (back from the line, out to your right, up, and how wide it sees), and
/// seconds from one throw to being ready for the next.
typedef Feel = ({
  double meter,
  double sway,
  double swayRate,
  ({double u, double down, double up}) reach,
  double keys,
  double mouse,
  ({double back, double side, double up, double fov}) cam,
  double between,
});

const Map<BarGame, Feel> feel = {
  BarGame.darts: (
    meter: 1.05,
    sway: 0.01,
    swayRate: 1,
    reach: (u: 0.32, down: 0.4, up: 0.32),
    keys: 0.12,
    mouse: 0.0004,
    cam: (back: 0.5, side: 0.62, up: 1.6, fov: 24),
    between: 0.65,
  ),
  BarGame.axe: (
    meter: 1.3,
    sway: 0.035,
    swayRate: 0.8,
    reach: (u: 1.1, down: 1.2, up: 0.95),
    keys: 0.45,
    mouse: 0.0012,
    cam: (back: 1.9, side: 0.9, up: 2.35, fov: 36),
    between: 1.35,
  ),
};

/// Let go with the meter under this and you didn't throw after all.
const double _minPower = 0.04;

enum ThrowStage { aim, wind, toss, wait }

/// What the thrower needs from the office.
class ThrowHooks {
  ThrowHooks({
    required this.holding,
    required this.toss,
    required this.aim,
    required this.done,
    required this.stand,
    required this.windBack,
    required this.letGo,
  });

  /// You stepped up to the line with a dart or an axe (or stepped back, null): everyone else sees it.
  final void Function(BarGame? game) holding;

  /// You let go of one: it leaves your hand at `from` (an axe turned `turn`), for where `toss` says.
  final void Function(Toss toss, vm.Vector3 from, double turn) toss;

  /// Where you're aiming on the target, while you are (null: not any more).
  final void Function(BarGame? game, double u, double v) aim;

  /// Stepped back from the line.
  final VoidCallback done;

  /// Puts you at the line for [game], facing the target (or back on your feet, null).
  final void Function(BarGame? game) stand;

  /// How far your character has the dart or axe drawn back (0–1).
  final void Function(double k) windBack;

  /// Your character throws: the release is called as it leaves the hand.
  final void Function(Release release) letGo;
}

/// The panel while you're at a line: the meter (its green), the last throw's mark, which throw is next, the round so far.
typedef ThrowPanel = ({BarGame game, double power, double last, String title, String info});

class Thrower {
  Thrower(this.hooks, {required this.now, math.Random? random}) : _rnd = random ?? math.Random();

  final ThrowHooks hooks;

  /// The page's clock (ms).
  final double Function() now;
  final math.Random _rnd;

  BarGame? _game;
  ThrowStage _stage = ThrowStage.aim;

  /// Where you aim on the target (u right, v up, meters from its middle), before your hand wanders off it.
  double aimU = 0, aimV = 0;
  double _swayT = 0;

  /// When you started drawing back, and when you can throw again (ms).
  double _windAt = 0, _readyAt = 0;

  /// Throws so far this round (it starts again after the last).
  int _n = 0;

  /// How hard the last throw was, marked on the meter.
  double _lastPower = -1;

  /// How drunk you are, for how much your hand wanders (see booze.dart).
  double drunk = 0;

  /// The camera's place and what it looks at (office space), while you're at a line.
  vm.Vector3 _camPos = vm.Vector3.zero();
  vm.Vector3 _camAt = vm.Vector3.zero();

  /// What the panel's bottom line says: this round's throws so far (see [setInfo]).
  String _info = '';
  final ValueNotifier<ThrowPanel?> panel = ValueNotifier(null);

  bool get active => _game != null;

  /// Which game you're throwing at, if you're at a line.
  BarGame? get playing => _game;

  ThrowStage? get doing => _game == null ? null : _stage;

  /// How wide the camera sees while you're at the line (degrees).
  double get fov => _game == null ? 55 : feel[_game]!.cam.fov;

  /// Which throw of the round is next (from 1).
  int get next => _game == null ? 1 : (_n % barRound[_game]!) + 1;

  /// How far the meter is up right now (0–1), while you draw back.
  double get power {
    final g = _game;
    if (_stage != ThrowStage.wind || g == null) return 0;
    return meterAt((now() - _windAt) / 1000, feel[g]!.meter);
  }

  /// Up to the line with a dart (or an axe) in hand, aiming at the middle. [camPos] and [camAt] are
  /// where the camera is now, for it to swing round from.
  void start(BarGame game, vm.Vector3 camPos, vm.Vector3 camAt) {
    if (_game != null) return;
    _game = game;
    _stage = ThrowStage.aim;
    aimU = 0;
    aimV = game == BarGame.darts ? 0.103 : 0;
    _n = 0;
    _lastPower = -1;
    _info = '';
    hooks.stand(game);
    _camPos = camPos.clone();
    _camAt = camAt.clone();
    hooks.holding(game);
    _render(game);
  }

  /// Back from the line, the dart (or axe) put down.
  void stop() {
    if (_game == null) return;
    _game = null;
    hooks.stand(null);
    hooks.holding(null);
    hooks.aim(null, 0, 0);
    panel.value = null;
    hooks.done();
  }

  /// The panel's bottom line: the round so far.
  void setInfo(String text) => _info = text;

  /// Every frame: aiming (with [left], [right], [up], [down] held), drawing back, and the panel.
  void update(double dt, {bool left = false, bool right = false, bool up = false, bool down = false}) {
    final game = _game;
    if (game == null) return;
    final f = feel[game]!;
    if (_stage == ThrowStage.aim || _stage == ThrowStage.wind) {
      final k = f.keys * dt;
      if (left) aimU -= k;
      if (right) aimU += k;
      if (up) aimV += k;
      if (down) aimV -= k;
      _clampAim();
    }
    if (_stage == ThrowStage.wait && now() >= _readyAt) _stage = ThrowStage.aim;
    _swayT += dt * f.swayRate;
    hooks.windBack(_stage == ThrowStage.wind ? power : 0);
    final (su, sv) = sway();
    hooks.aim(_stage == ThrowStage.aim || _stage == ThrowStage.wind ? game : null, aimU + su, aimV + sv);
    hooks.stand(game);
    _render(game);
  }

  /// Where your hand has wandered off your aim, right now.
  (double, double) sway() {
    final f = feel[_game]!;
    final t = _swayT;
    final a = f.sway * (1 + 2.5 * math.min(1.3, drunk));
    return (
      a * (math.sin(t * 1.3) + 0.5 * math.sin(t * 2.9 + 1)) * 0.67,
      a * (math.cos(t * 1.1 + 2) + 0.5 * math.sin(t * 2.3)) * 0.67,
    );
  }

  void _clampAim() {
    final r = feel[_game]!.reach;
    aimU = aimU.clamp(-r.u, r.u);
    aimV = aimV.clamp(-r.down, r.up);
  }

  /// Space down or up at the line. True when it was the thrower's.
  bool key(KeyEvent e) {
    if (_game == null || e.physicalKey != PhysicalKeyboardKey.space) return false;
    if (e is KeyDownEvent) windUp();
    if (e is KeyUpEvent) letGo();
    return true;
  }

  /// Start drawing back (Space or the mouse button down).
  void windUp() {
    if (_game == null || _stage != ThrowStage.aim || now() < _readyAt) return;
    _stage = ThrowStage.wind;
    _windAt = now();
  }

  /// Let go (Space or the mouse button up): throws, unless the meter barely moved.
  void letGo() {
    final game = _game;
    if (_stage != ThrowStage.wind || game == null) return;
    final pw = power;
    if (pw < _minPower) return putBack();
    final (su, sv) = sway();
    _n = (_n % barRound[game]!) + 1;
    final l = landing(game, aimU + su, aimV + sv, pw, (_rnd.nextDouble() * 2 - 1, _rnd.nextDouble() * 2 - 1));
    final out = Toss(game: game, u: l.u, v: l.v, stick: l.stick, n: _n);
    _lastPower = pw;
    _stage = ThrowStage.toss;
    hooks.letGo((from, turn) {
      if (_game != game) return;
      hooks.toss(out, from, turn);
      _stage = ThrowStage.wait;
      _readyAt = now() + feel[game]!.between * 1000;
    });
  }

  /// Drawn back and let go without throwing (or tabbed away mid-draw): back to aiming.
  void putBack() {
    if (_game == null) return;
    _stage = ThrowStage.aim;
    hooks.windBack(0);
  }

  /// The captured mouse moved by [dx], [dy] pixels: the aim moves with it.
  bool look(double dx, double dy) {
    final g = _game;
    if (g == null) return false;
    if (_stage == ThrowStage.toss) return true;
    final f = feel[g]!;
    aimU += dx.clamp(-250, 250) * f.mouse;
    aimV -= dy.clamp(-250, 250) * f.mouse;
    _clampAim();
    return true;
  }

  /// The free mouse points along [ray] (office space): the aim goes wherever that meets the target.
  bool pointAt(vm.Ray ray) {
    final g = _game;
    if (g == null) return false;
    if (_stage == ThrowStage.toss) return true;
    final t = targetFrame(g);
    final n = vm.Vector3(t.out.x, 0, t.out.z);
    final denom = n.dot(ray.direction);
    if (denom.abs() < 1e-6) return true;
    final d = n.dot(vm.Vector3(t.x, t.y, t.z) - ray.origin) / denom;
    if (d < 0) return true;
    final hit = ray.at(d);
    aimU = (hit.x - t.x) * t.right.x + (hit.z - t.z) * t.right.z;
    aimV = hit.y - t.y;
    _clampAim();
    return true;
  }

  /// Over your right shoulder, looking at the middle of the target: [camera] narrowed onto it.
  PerspectiveCamera camera(PerspectiveCamera camera, double dt) {
    final g = _game;
    if (g == null) return camera;
    final c = feel[g]!.cam;
    final s = throwSpot(g);
    final t = targetFrame(g);
    final fx = math.sin(s.facing), fz = math.cos(s.facing);
    final want = vm.Vector3(s.x - fx * c.back + t.right.x * c.side, c.up, s.z - fz * c.back + t.right.z * c.side);
    final look = vm.Vector3(t.x, t.y, t.z);
    final k = 1 - math.exp(-dt * 7);
    _camPos += (want - _camPos) * k;
    _camAt += (look - _camAt) * k;
    return PerspectiveCamera(
      fovRadiansY: c.fov * math.pi / 180,
      position: toEngine(_camPos),
      target: toEngine(_camAt),
      fovNear: camera.fovNear,
      fovFar: camera.fovFar,
    );
  }

  /// The meter, which throw of the round is next, and the round so far.
  void _render(BarGame game) {
    final next = _stage == ThrowStage.aim || _stage == ThrowStage.wind ? this.next : _n;
    final title = game == BarGame.darts
        ? '🎯 Darts · dart $next of ${barRound[BarGame.darts]}'
        : '🪓 Axe throwing · axe $next of ${barRound[BarGame.axe]}';
    final info = _info.isNotEmpty
        ? _info
        : game == BarGame.darts
        ? 'Aim with the mouse · hold Space and let go in the green'
        : 'Let go in the green to stick it';
    final p = (game: game, power: _stage == ThrowStage.wind ? power : 0.0, last: _lastPower, title: title, info: info);
    if (p != panel.value) panel.value = p;
  }
}
