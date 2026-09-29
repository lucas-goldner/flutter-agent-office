// Your own hands in first person: a port of world/hands.ts.
//
// In three.js they were a scene of their own, drawn after the world with the depth buffer cleared,
// so they never poked through desks or walls. flutter_scene 0.23.0 has no clearDepth between draws,
// so here they are a [Node] ([Hands.root]) the world places at the camera each frame ([place]),
// laid out in camera space (-z forward) under it, and two ways to draw them:
//
//  * Plainly, in the world: the arms reach 0.24–0.64 m ahead of the eye, beyond the 0.1 near plane,
//    so they draw, but they do sink into a wall or a desk you stand right up against.
//  * As an overlay, like the old clearDepth pass: every hands node is on [Hands.layer]; render the
//    world with a view whose layerMask leaves that layer out, and the hands with [overlayView] on
//    top. Each RenderView renders into its own target and they composite in `order`, so the hands'
//    view has its own depth buffer and nothing in the world can cover them. (Needs the scene to
//    have no Skybox, which would fill the overlay's background: the office draws its sky as meshes.)

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'character.dart' show cigarette, coffeeMug, dragCurve, kReachTime, kSmokeCycle, reachCurve, setEmissive;
import 'package:office_shared/protocol.dart' show CarriedIssue;

import 'card.dart';
import 'geo.dart';
import 'toon.dart';

class HandsInput {
  const HandsInput({
    required this.yaw,
    required this.pitch,
    this.walkPhase = 0,
    this.walking = false,
    this.airborne = false,
    this.jitter = 0,
  });

  final double yaw;
  final double pitch;
  final double walkPhase;
  final bool walking;
  final bool airborne;

  /// 0 (steady) to 1: one coffee too many.
  final double jitter;
}

/// Lifting the mug for a sip and lowering it again, in seconds.
const double _sipTime = 1.1;

class _Arm {
  _Arm(this.group, this.base, this.baseRot);
  final Node group;
  final vm.Vector3 base;
  final vm.Vector3 baseRot;
}

class Hands {
  Hands(String shirt, String skin) {
    _sleeve = toonUnique(hex(shirt));
    _skin = toonUnique(hex(skin));
    _right = _arm(1);
    _left = _arm(-1);
    // In the left hand, handle in the palm, standing upright however the arm is turned.
    _mug = coffeeMug()
      ..position = vm.Vector3(0.09, -0.035, -0.03)
      ..rotation = euler(_left.baseRot.x, _left.baseRot.y, _left.baseRot.z).inverted()
      ..visible = false;
    _left.group.add(_mug);
    // Held between the fingers of the right hand, lit end out past the knuckles.
    final cig = cigarette();
    _cig = cig.group
      ..scale = vm.Vector3.all(0.55)
      ..rotation = euler(0.35, math.pi + 0.5, 0)
      ..position = vm.Vector3(-0.035, 0.03, -0.075)
      ..visible = false;
    _ember = cig.ember;
    _right.group.add(_cig);
    setLayers(root, layer);
  }

  /// The render layer every hands node is on (bit 5), for drawing them as an overlay.
  static const int layer = 1 << 5;

  /// Parent this in the world; [place] moves it to the camera. Its children are in camera space.
  final Node root = Node(name: 'hands');

  late final PreprocessedMaterial _sleeve;
  late final PreprocessedMaterial _skin;
  late final _Arm _right;
  late final _Arm _left;
  double _reachT = -1;
  late final Node _mug;

  /// Seconds into a sip (negative while it waits for the reach to finish), or null.
  double? _sipT;
  final vm.Vector2 _sway = vm.Vector2.zero();
  ({double yaw, double pitch})? _last;
  double _air = 0;
  double _walk = 0;
  late final Node _cig;
  late final PreprocessedMaterial _ember;
  double _emberGlow = 0.3;

  /// Seconds into a smoke break, or -1. Runs in step with your character's (see Person.setSmoking).
  double _smokeT = -1;

  /// Moves the hands to the camera: [eye] is where it is, [forward] the way it looks (any length),
  /// both in the space [root]'s parent is in (the office's, as the TS had them, not the engine's
  /// mirrored world). The hands' own -z points along [forward], +y as close to up as it can be.
  void place(vm.Vector3 eye, vm.Vector3 forward) {
    final back = -forward.normalized();
    var right = vm.Vector3(0, 1, 0).cross(back);
    if (right.length2 < 1e-8) right = vm.Vector3(1, 0, 0);
    right.normalize();
    final up = back.cross(right);
    final m = vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(right.x, right.y, right.z, 0))
      ..setColumn(1, vm.Vector4(up.x, up.y, up.z, 0))
      ..setColumn(2, vm.Vector4(back.x, back.y, back.z, 0))
      ..setColumn(3, vm.Vector4(eye.x, eye.y, eye.z, 1));
    root.localTransform = m;
  }

  /// The view to draw the hands with on top of the world (see the top of this file): a camera at
  /// the last [place] (worked out in engine space, mirror and all), seeing only [layer], with the
  /// old hands camera's 0.01–5 m range.
  RenderView overlayView({double fovRadiansY = 55 * math.pi / 180, int order = 1}) {
    final eye = pointIn(null, root, vm.Vector3.zero());
    final ahead = pointIn(null, root, vm.Vector3(0, 0, -1));
    final up = pointIn(null, root, vm.Vector3(0, 1, 0)) - eye;
    return RenderView(
      camera: PerspectiveCamera(fovRadiansY: fovRadiansY, position: eye, target: ahead, up: up, fovNear: 0.01, fovFar: 5),
      layerMask: layer,
      order: order,
    );
  }

  /// Puts a lit cigarette in your right hand, or takes it away.
  void setSmoking(bool on) {
    if (on == _smokeT >= 0) return;
    _smokeT = on ? 0 : -1;
    _cig.visible = on;
  }

  /// Where the cigarette's lit end is, in the space [root] is placed in (the office's, like [place]).
  vm.Vector3 cigTip() => pointIn(root.parent, _cig, vm.Vector3(0, 0, 0.09));

  void setColor(String shirt) => setToonColor(_sleeve, hex(shirt));

  void setSkin(String skin) => setToonColor(_skin, hex(skin));

  /// How lit it is where you stand, 0–1 (see Sky.lightAt): your hands go dark out on a night street.
  /// Dims the sleeve and skin (the office's shared light is the hands' light here). Call it after
  /// Toon.updateLight, which resets them.
  void setLight(double level) {
    final k = 0.25 + 0.75 * level;
    final l = Toon.light;
    for (final m in [_sleeve, _skin]) {
      m.parameters
        ..setFloat('sun_intensity', l.sunIntensity * k)
        ..setFloat('hemi_intensity', l.hemiIntensity * k)
        ..setFloat('ambient', l.ambient * k);
    }
  }

  /// Reach out with the right hand.
  void reach() => _reachT = 0;

  /// A mug of coffee in the left hand, or not. It waits while the hands are full (a card).
  void holdMug(bool on) {
    _wantsMug = on;
    _mug.visible = on && !(_card?.held ?? false);
  }

  bool _wantsMug = false;

  /// An issue card off the board, held low in front of you in both hands, tipped back so you look
  /// down onto its front.
  Node? _cardHolder;
  HeldCard? _card;

  /// 0 → 1 as the card comes up into view and the hands close in on it.
  double _carryK = 0;

  /// An issue card in both hands, or none (null). The mug waits while the hands are full.
  void carry(CarriedIssue? card) {
    if (card == null && _card == null) return;
    _card ??= () {
      final holder = _cardHolder = Node(name: 'card-holder')..rotation = euler(-0.35, 0, 0);
      root.add(holder);
      return HeldCard(holder, 0.24, onAdd: (n) => setLayers(n, layer));
    }();
    final was = _card!.held;
    _card!.set(card);
    if (!was) _carryK = 0;
    holdMug(_wantsMug);
  }

  /// Raise the mug for a sip, once the right hand is back from the coffee machine.
  void sip() => _sipT = -kReachTime * 0.6;

  _Arm _arm(int side) {
    final group = Node(name: side == 1 ? 'right-hand' : 'left-hand');
    // Sleeve runs from the wrist back past the camera, so its far end is always off screen.
    group.add(mesh(capsuleData(0.058, 0.42, 6, 14).rotateX(math.pi / 2).build(), _sleeve, 0, 0, 0.34, false));
    group.add(mesh(cylinderData(0.068, 0.068, 0.045, 18).rotateX(math.pi / 2).build(), toon(hex('#fffaf3')), 0, 0, 0.075, false));
    // Cartoon mitten: a chunky palm, a thumb on the inside, and a pointing finger on the right hand.
    group.add(mesh(sphere(0.062, 18, 14), _skin, 0, 0, 0, false)..scale = vm.Vector3(1, 0.78, 1.18));
    group.add(
      mesh(capsuleData(0.02, 0.03, 4, 10).rotateX(math.pi / 2).build(), _skin, -side * 0.05, 0.014, -0.02, false)
        ..rotation = euler(0, side * 0.55),
    );
    if (side == 1) {
      group.add(mesh(capsuleData(0.019, 0.05, 4, 10).rotateX(math.pi / 2).build(), _skin, -0.016, 0.022, -0.085, false));
    }
    final base = vm.Vector3(side * 0.25, -0.185, -0.44);
    final baseRot = vm.Vector3(0.2, side * 0.22, side * -0.25);
    group
      ..position = base
      ..rotation = euler(baseRot.x, baseRot.y, baseRot.z);
    root.add(group);
    return _Arm(group, base, baseRot);
  }

  void update(double dt, double t, HandsInput s) {
    // Hands lag a touch behind quick turns of the head.
    final last = _last;
    if (last != null && dt > 0) {
      final dyaw = math.atan2(math.sin(s.yaw - last.yaw), math.cos(s.yaw - last.yaw));
      final dpitch = s.pitch - last.pitch;
      final tx = (dyaw / dt * 0.012).clamp(-0.05, 0.05);
      final ty = (-dpitch / dt * 0.01).clamp(-0.04, 0.04);
      _sway.x += (tx - _sway.x) * math.min(1, dt * 10);
      _sway.y += (ty - _sway.y) * math.min(1, dt * 10);
    }
    _last = (yaw: s.yaw, pitch: s.pitch);
    _air += ((s.airborne ? 1 : 0) - _air) * math.min(1, dt * 8);
    _walk += ((s.walking ? 1 : 0) - _walk) * math.min(1, dt * 8);

    final breathe = math.sin(t * 1.7) * 0.004;
    final step = math.sin(s.walkPhase) * _walk;
    final bounce = math.sin(s.walkPhase * 2) * 0.006 * _walk;
    final k = _reachT >= 0 ? reachCurve(_reachT / kReachTime) : 0.0;
    if (_reachT >= 0) {
      _reachT += dt;
      if (_reachT >= kReachTime) _reachT = -1;
    }
    var sip = 0.0;
    if (_sipT != null) {
      _sipT = _sipT! + dt;
      sip = reachCurve(_sipT! / _sipTime);
      if (_sipT! >= _sipTime) _sipT = null;
    }
    final shake = s.jitter * 0.004;

    final held = _card?.held ?? false;
    _carryK += ((held ? 1 : 0) - _carryK) * math.min(1, dt * 7);
    final carry = _carryK;
    final pose = <int, (vm.Vector3, vm.Vector3)>{};
    for (final (arm, side) in [(_right, 1), (_left, -1)]) {
      final p = arm.base.clone();
      p.x += _sway.x + side * _air * 0.03 + step * 0.008;
      p.y += _sway.y + breathe + bounce + _air * 0.05;
      // Arms swing opposite each other while walking.
      p.z += side * step * 0.025;
      p.x += shake * math.sin(t * 97 + side);
      p.y += shake * math.sin(t * 131 + side * 2);
      final r = arm.baseRot.clone();
      r.x += _air * 0.2;
      // Holding a card: both hands in on its bottom corners, palms turned toward it, so the title shows.
      p.x -= side * 0.08 * carry;
      p.z -= 0.03 * carry;
      r.z += side * 0.35 * carry;
      pose[side] = (p, r);
    }
    // The card rides along with the hands, coming up from below as you take it.
    _cardHolder?.position = vm.Vector3(
      _sway.x + step * 0.008,
      _sway.y + breathe + bounce + _air * 0.05 - 0.115 - 0.3 * (1 - carry),
      -0.5,
    );
    // The reach: the right hand jabs out toward the crosshair, the left pulls back a little.
    final (rp, rr) = pose[1]!;
    final (lp, lr) = pose[-1]!;
    rp.x -= 0.16 * k;
    rp.y += 0.09 * k;
    rp.z -= 0.2 * k;
    rr.x += 0.3 * k;
    rr.y += 0.15 * k;
    rr.z += 0.22 * k;
    lp.y -= 0.025 * k;
    lp.z += 0.03 * k;
    // The sip: the mug comes up to your mouth and tips toward you.
    lp.x += 0.17 * sip;
    lp.y += 0.13 * sip;
    lp.z += 0.14 * sip;
    lr.x += 0.7 * sip;
    // A drag: the cigarette hand comes up to your mouth, just under the camera, and back down.
    if (_smokeT >= 0) {
      _smokeT += dt;
      final d = s.walking || s.airborne ? 0.0 : dragCurve(_smokeT % kSmokeCycle);
      rp.x -= 0.2 * d;
      rp.y += 0.02 * d;
      rp.z += 0.3 * d;
      rr.x += 0.5 * d;
      _emberGlow += ((d > 0.9 ? 1.4 : 0.3) - _emberGlow) * math.min(1, dt * 6);
      setEmissive(_ember, hex('#ff3b00'), _emberGlow);
    }
    _right.group
      ..position = rp
      ..rotation = euler(rr.x, rr.y, rr.z);
    _left.group
      ..position = lp
      ..rotation = euler(lr.x, lr.y, lr.z);
  }
}

/// Puts [node] and everything under it on render [layers] (a node's layers aren't inherited).
void setLayers(Node node, int layers) {
  node.layers = layers;
  for (final c in node.children) {
    setLayers(c, layers);
  }
}
