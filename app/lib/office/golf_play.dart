// Teeing off from the balcony (golf.ts): E at the tee puts a club in your hands, and the camera goes
// down low behind the ball, looking down the line at the hole. The mouse (or A and D) aims, W and S
// pick the loft, and holding Space takes the club back while the power meter runs up and down: let go
// to hit it. The camera follows the ball out to wherever it stops, then comes back to the tee for the
// next one. E puts the club back in the bag.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' show Node, PerspectiveCamera;
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../interop/portable.dart' show storageGet, storageSet;
import '../state/store.dart' show nowMs;
import '../ui/hud_parts.dart';
import '../ui/modal.dart';
import '../world/golf.dart';
import '../world/space.dart';
import 'controller.dart';

/// The power meter runs from nothing to full in this long, then back down again.
const double _meter = 1.3;

/// A and D (and the arrow keys) turn the aim this fast, in radians a second; W and S change the loft.
const double _turn = 0.3;
final double _loftRate = 25 * math.pi / 180;
final double loftStart = 42 * math.pi / 180;

/// How far off line (radians) and off the power meter (a fraction of it) a shot can come off the club.
final double _mishitAim = 1.4 * math.pi / 180;
const double _mishitPower = 0.025;

/// The office takes one shot from you at a time, this far apart (in ms).
const double _betweenShots = 1000;

/// Let go with the meter under this and it's a practice swing: nothing happens.
const double _minPower = 0.03;

/// How long the camera stays over a ball that's stopped, before going back to the tee.
const double _linger = 2.6;
const double _lingerHoled = 4.5;

/// Following the ball: this far behind it, and this far up.
const double _chaseBack = 4.5;
const double _chaseUp = 1.7;

/// Behind the ball on the tee: back along the line, out to the right (away from the golfer), and up.
const double _teeBack = 1.38;
const double _teeSide = 0.35;
const double _teeUp = 1;
const double _teeUpMax = 6;

/// The swing takes this long from the top to the ball.
const double _impact = 0.25;

enum GolfStage { aim, charge, swing, watch }

const _recordKey = 'agent-office.golf';

double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));

/// Your closest shot to the pin so far (meters) and how many you've holed in one, kept in this browser.
({double? best, int holes}) golfRecord() {
  try {
    final r = jsonDecode(storageGet(_recordKey) ?? '{}');
    if (r is Map) return (best: (r['best'] as num?)?.toDouble(), holes: (r['holes'] as num?)?.toInt() ?? 0);
  } catch (_) {
    // blocked or garbage
  }
  return (best: null, holes: 0);
}

void _saveRecord(({double? best, int holes}) r) =>
    storageSet(_recordKey, jsonEncode({if (r.best != null) 'best': r.best, 'holes': r.holes}));

/// The golf panel: which hole, the power meter, the loft and the aim.
typedef GolfPanel = ({double power, double last, String info});

class GolfPlay {
  GolfPlay(this.c, this.teeBallNode) {
    balls.onRest = _rest;
    _sub = c.store.rooms.golf.listen((m) {
      if (m.id == c.store.you) return;
      _theirShot(m.id, (yaw: m.yaw, loft: m.loft, power: m.power));
    });
  }

  final OfficeController c;
  final Node teeBallNode;
  late final GolfBalls balls = GolfBalls(c.labels);
  StreamSubscription<GolfMsg>? _sub;

  GolfStage? _stage;

  /// Which way you aim (a heading: 0 is south, +z, and it turns toward +x), and the loft you've picked.
  double aim = 0;
  double loft = loftStart;
  double _chargeAt = 0;
  double _lastPower = -1;
  Shot? _shot;
  double _swingT = 0;
  double _hitAt = -1e9;

  /// Until when ([nowMs]) the tee has no ball on it: someone just hit it.
  double _teeEmptyUntil = 0;

  /// The camera's own place and what it looks at (office coordinates), while it's the golf camera.
  vm.Vector3 _camPos = vm.Vector3.zero();
  vm.Vector3 _camAt = vm.Vector3.zero();

  /// What the panel shows while you're at the tee (null otherwise).
  final ValueNotifier<GolfPanel?> panel = ValueNotifier(null);

  bool get active => _stage != null;
  GolfStage? get stage => _stage;

  /// How far down the street is from this floor.
  double get street => streetBelow(0);

  void dispose() => _sub?.cancel();

  /// How far the power meter is up right now (0–1), while Space is held.
  double get power {
    if (_stage != GolfStage.charge) return 0;
    final p = ((nowMs() - _chargeAt) / 1000 / _meter) % 2;
    return p > 1 ? 2 - p : p;
  }

  Flight _here(Shot s) => fly(s, street, 0);

  /// Who's at the tee on this floor already, if anyone.
  String? teeTaken() {
    for (final p in c.store.peers.values) {
      if (p.id != c.store.you && p.golfing == true && c.store.onMyFloor(p)) return p.name;
    }
    return null;
  }

  /// E at the tee: take a club out and step up to the ball.
  void start() {
    if (_stage != null) return;
    final other = teeTaken();
    if (other != null) return toast('🏌️ $other is on the tee — wait your turn', ToastKind.warn);
    if (c.player.seat != null) c.standUp();
    _stage = GolfStage.aim;
    aim = pinYaw;
    c.player.enabled = false;
    c.player.input.clear();
    _stand();
    c.player.camYaw = aim + math.pi;
    _camPos = c.player.camPos.clone();
    _camAt = c.player.camTarget.clone();
    c.net.send(const ActCmd(golf: true));
  }

  /// The club back in the bag, and you back on your feet beside the tee.
  void stop() {
    if (_stage == null) return;
    _stage = null;
    _shot = null;
    final p = c.player;
    p.enabled = !ModalStack.instance.open;
    p.lookPitch = -0.08;
    p.camYaw = p.facing + math.pi;
    c.net.send(const ActCmd(golf: false));
    panel.value = null;
  }

  /// Where you stand for the aim you've got: square to the line, over the ball.
  void _stand() {
    final s = stance(aim);
    final p = c.player;
    p.pos.setValues(s.x, 0, s.z);
    p.facing = s.facing;
  }

  /// Space down and up at the tee, and E to put the club back. True when it was golf's.
  bool key(KeyEvent e) {
    if (_stage == null) return false;
    final k = e.physicalKey;
    if (k == PhysicalKeyboardKey.keyE) {
      if (e is KeyDownEvent) stop();
      return true;
    }
    if (k != PhysicalKeyboardKey.space) {
      // Nothing else is in reach at the tee.
      return e is KeyDownEvent &&
          (k == PhysicalKeyboardKey.keyF || k == PhysicalKeyboardKey.keyP || k == PhysicalKeyboardKey.keyX);
    }
    if (e is KeyDownEvent) {
      if (_stage == GolfStage.aim) {
        if (nowMs() - _hitAt < _betweenShots) return true;
        _stage = GolfStage.charge;
        _chargeAt = nowMs();
      } else if (_stage == GolfStage.watch) {
        _backToTee();
      }
    } else if (e is KeyUpEvent && _stage == GolfStage.charge) {
      final pw = power;
      if (pw < _minPower) {
        _stage = GolfStage.aim;
        return true;
      }
      // Nobody hits it exactly the same way twice: a touch off line, a touch more or less.
      final r = math.Random();
      final yaw = aim + (r.nextDouble() - 0.5) * _mishitAim;
      _shot = (yaw: yaw, loft: loft, power: math.min(1.0, pw * (1 + (r.nextDouble() - 0.5) * _mishitPower)));
      _lastPower = pw;
      _stage = GolfStage.swing;
      _swingT = 0;
      c.me.reach();
    }
    return true;
  }

  void _backToTee() {
    _stage = GolfStage.aim;
    c.player.camYaw = aim + math.pi;
  }

  /// Someone else on the floor hit one: their ball, off the same tee.
  void _theirShot(String id, Shot shot) {
    final p = c.store.peers[id];
    if (p == null || !c.store.onMyFloor(p)) return;
    c.personOf(id)?.reach();
    final floor = c.store.floor;
    Timer(const Duration(milliseconds: 250), () {
      if (c.store.floor != floor) return;
      balls.launch(_here(shot), p.name, false);
      _teeEmptyUntil = nowMs() + 1800;
    });
  }

  void _rest(Flight f, String who, bool mine) {
    if (f.holed) c.confetti.burst(GolfHole.x, street + 1.2, GolfHole.z, 260, 1.4);
    if (!mine) {
      if (f.holed) toast('🏆 $who got a hole in one!');
      return;
    }
    var rec = golfRecord();
    if (f.holed) {
      rec = (best: rec.best, holes: rec.holes + 1);
      toast(rec.holes == 1 ? '🏆 HOLE IN ONE!' : "🏆 HOLE IN ONE! That's ${rec.holes}");
    } else if (f.fromPin.isFinite && (rec.best == null || f.fromPin < rec.best!)) {
      if (rec.best != null) toast('⛳ ${pinText(f.fromPin)} from the pin — your best yet!');
      rec = (best: f.fromPin, holes: rec.holes);
    } else {
      return;
    }
    _saveRecord(rec);
  }

  /// Every frame: the balls fly on; at the tee, aiming, the swing, and the camera. Returns the camera to draw with.
  PerspectiveCamera update(PerspectiveCamera camera, double dt) {
    balls.update(dt);
    teeBallNode.visible = _stage != GolfStage.watch && nowMs() > _teeEmptyUntil;
    if (_stage == null) return camera;
    // The camera's behind the ball, and you're the one holding the club.
    c.me.root.visible = true;
    // Your feet stay at the tee (a window closing hands the keys back to walking otherwise).
    c.player.enabled = false;
    c.player.input.clear();
    final p = c.player;
    if (_stage == GolfStage.aim || _stage == GolfStage.charge) {
      final keys = HardwareKeyboard.instance.physicalKeysPressed;
      bool held(PhysicalKeyboardKey a, PhysicalKeyboardKey b) =>
          !ModalStack.instance.open && (keys.contains(a) || keys.contains(b));
      // The mouse turns your view as it always does (camYaw); that's the aim, along with the keys.
      var a = _wrap(p.camYaw - math.pi);
      if (held(PhysicalKeyboardKey.keyA, PhysicalKeyboardKey.arrowLeft)) a += _turn * dt;
      if (held(PhysicalKeyboardKey.keyD, PhysicalKeyboardKey.arrowRight)) a -= _turn * dt;
      aim = a.clamp(-aimMax, aimMax);
      if (held(PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.arrowUp)) loft = math.min(loftMax, loft + _loftRate * dt);
      if (held(PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.arrowDown)) {
        loft = math.max(loftMin, loft - _loftRate * dt);
      }
      _stand();
    }
    p.camYaw = aim + math.pi;
    if (_stage == GolfStage.swing) {
      _swingT += dt;
      final shot = _shot;
      if (_swingT >= _impact && shot != null) {
        _hitAt = nowMs();
        c.net.send(GolfCmd(yaw: shot.yaw, loft: shot.loft, power: shot.power));
        balls.launch(_here(shot), c.store.profile.name, true);
        _shot = null;
        _stage = GolfStage.watch;
      }
    }
    if (_stage == GolfStage.watch) {
      final b = balls.mine;
      if (b == null || b.still > (b.flight.holed ? _lingerHoled : _linger)) _backToTee();
    }
    _renderPanel();
    return _placeCamera(camera, dt);
  }

  PerspectiveCamera _placeCamera(PerspectiveCamera camera, double dt) {
    final b = _stage == GolfStage.watch ? balls.mine : null;
    // A ball that never left the balcony is watched from the tee.
    final chase = b != null && b.flight.lie != Lie.deck ? b : null;
    late vm.Vector3 want, target;
    if (chase != null && chase.still >= 0 && chase.flight.fromPin.isFinite) {
      // Down: back from it and the pin, from the tee's side, far enough to see both.
      final holed = chase.flight.holed;
      target = vm.Vector3((chase.at.x + GolfHole.x) / 2, street + (holed ? 1.4 : 0.4), (chase.at.z + GolfHole.z) / 2);
      final back = math.min(22.0, (holed ? 8 : 5) + chase.flight.fromPin * 0.9);
      want = vm.Vector3(
        target.x - math.sin(pinYaw) * back,
        street + 2 + back * 0.35,
        target.z - math.cos(pinYaw) * back,
      );
    } else if (chase != null) {
      // Behind the ball the way it was hit, a little above it, looking at it.
      final yaw = chase.flight.shot.yaw;
      want = vm.Vector3(
        chase.at.x - math.sin(yaw) * _chaseBack,
        chase.at.y + _chaseUp,
        chase.at.z - math.cos(yaw) * _chaseBack,
      );
      target = chase.at.clone();
    } else {
      // Down low behind the ball on the tee, looking down the line: the ball at the bottom of the
      // view, the hole further up it.
      final sin = math.sin(aim), cos = math.cos(aim);
      final depth = teeBall.y - street;
      final edge = (Balcony.maxZ - teeBall.z + cos * _teeBack) / math.max(0.3, cos);
      final reach = pinDistance + _teeBack;
      final up = ((edge * depth) / (reach - edge) + 0.5).clamp(_teeUp, _teeUpMax);
      want = vm.Vector3(
        teeBall.x - sin * _teeBack - cos * _teeSide,
        teeBall.y + up,
        teeBall.z - cos * _teeBack + sin * _teeSide,
      );
      double down(double y, double d) => math.atan2(y - want.y, d);
      final a = down(teeBall.y, _teeBack), z = down(street, pinDistance + _teeBack);
      final pitch = a + (z - a) * 0.56;
      target = vm.Vector3(want.x + sin * math.cos(pitch), want.y + math.sin(pitch), want.z + cos * math.cos(pitch));
    }
    final k = 1 - math.exp(-dt * (chase != null ? 5 : 7));
    _camPos += (want - _camPos) * k;
    _camAt += (target - _camAt) * k;
    return PerspectiveCamera(
      fovRadiansY: camera.fovRadiansY,
      position: toEngine(_camPos),
      target: toEngine(_camAt),
      fovNear: camera.fovNear,
      fovFar: camera.fovFar,
    );
  }

  void _renderPanel() {
    final pw = _stage == GolfStage.charge
        ? power
        : _stage == GolfStage.aim
        ? 0.0
        : _lastPower;
    final off = (aim - pinYaw) * 180 / math.pi;
    final where = off.abs() < 0.5 ? 'at the pin' : '${off.abs().toStringAsFixed(0)}° ${off > 0 ? 'left' : 'right'}';
    final next = (
      power: math.max(0.0, pw),
      last: _lastPower,
      info: 'Loft ${(loft * 180 / math.pi).toStringAsFixed(0)}° · Aim $where',
    );
    if (next != panel.value) panel.value = next;
  }

  /// At the tee: how to aim and swing, or how to get back to it while the ball's out there.
  (String, List<HintPart>) hint() => switch (_stage) {
    GolfStage.charge => (
      'golf|charge',
      [const HintTitle('⛳ Let go to hit it'), const HintAside('the fuller the meter, the further it goes')],
    ),
    GolfStage.watch => (
      'golf|watch',
      [
        const HintTitle('⛳ Watching your ball'),
        const HintKey('Space', 'Back to the tee'),
        const HintKey('E', 'Put the club back'),
      ],
    ),
    _ => (
      'golf|aim',
      [
        const HintTitle('⛳ On the tee'),
        const HintKey('Mouse / A D', 'Aim'),
        const HintKey('W S', 'Loft'),
        const HintKey('Space', 'Hold to swing'),
        const HintKey('E', 'Put the club back'),
      ],
    ),
  };

  /// The hint at the tee itself.
  (String, List<HintPart>) teeHint() {
    final other = teeTaken();
    if (other != null) {
      return ('taken|$other', [const HintTitle('⛳ Golf tee'), HintAside('🏌️ ${clip(other, 24)} is teeing off')]);
    }
    final r = golfRecord();
    final about = [
      if (r.holes > 0) '🏆 ${r.holes} hole${r.holes == 1 ? '' : 's'} in one',
      r.best != null ? 'your best ${pinText(r.best!)} from the pin' : "the pin's ${pinDistance.round()} m out",
    ].join(' · ');
    return (about, [const HintTitle('⛳ Golf tee'), HintAside(about), const HintKey('E', 'Tee off')]);
  }
}
