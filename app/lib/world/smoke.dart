// Cigarette smoke: soft grey puffs that drift up on the breeze, spread out and fade. A port of
// world/smoke.ts: every puff is one instance of a camera-facing quad, so it's a single draw.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'text.dart' show pictureTexture, verticalPlane;

const int _max = 160;

class _Puff {
  final vm.Vector3 pos = vm.Vector3.zero();
  final vm.Vector3 vel = vm.Vector3.zero();
  double age = 0, life = 1, size0 = 0, size1 = 0, alpha = 0, spin = 0;
}

class Smoke {
  Smoke({math.Random? random}) : _rnd = random ?? math.Random() {
    _mat = UnlitMaterial()
      ..alphaMode = AlphaMode.blend
      ..doubleSided = true;
    _mesh = InstancedMesh(geometry: verticalPlane(1, 1), material: _mat, sortTransparentInstances: false);
    for (var i = 0; i < _max; i++) {
      _mesh.addInstance(_hidden, color: vm.Vector4(0.72, 0.76, 0.81, 0)); // #dde2e8, linear
    }
    node = Node(name: 'smoke')
      ..addComponent(InstancedMeshComponent(_mesh))
      ..castsShadows = false
      ..frustumCulled = false
      ..visible = false;
    _puffTexture().then((t) => _mat.baseColorTexture = t);
  }

  final math.Random _rnd;
  late final UnlitMaterial _mat;
  late final InstancedMesh _mesh;
  late final Node node;
  final List<_Puff?> _slots = List.filled(_max, null);
  int _next = 0;
  static final vm.Matrix4 _hidden = vm.Matrix4.diagonal3Values(0, 0, 0);

  double _r() => _rnd.nextDouble();

  /// A thin wisp curling up off a cigarette's lit end.
  void wisp(vm.Vector3 at) =>
      _emit(at, vm.Vector3((_r() - 0.5) * 0.06, 0.3 + _r() * 0.1, (_r() - 0.5) * 0.06), 0.06, 0.4, 2.4, 0.5);

  /// A lungful blown out along [dir] (a unit vector).
  void exhale(vm.Vector3 at, vm.Vector3 dir) {
    for (var i = 0; i < 8; i++) {
      final speed = 0.95 - i * 0.08;
      final v = dir * speed
        ..x += (_r() - 0.5) * 0.15
        ..y += 0.12 + (_r() - 0.5) * 0.1
        ..z += (_r() - 0.5) * 0.15;
      _emit(at + dir * (i * 0.03), v, 0.12, 0.75 + _r() * 0.35, 2.6 + _r() * 0.8, 0.6);
    }
  }

  void _emit(vm.Vector3 at, vm.Vector3 vel, double size0, double size1, double life, double alpha) {
    // The oldest puff makes way when all are in use.
    final i = _next;
    _next = (_next + 1) % _max;
    final p = _slots[i] ??= _Puff();
    p.pos.setFrom(at);
    p.vel.setFrom(vel);
    p.spin = _r() * math.pi * 2;
    p
      ..age = 0
      ..life = life
      ..size0 = size0
      ..size1 = size1
      ..alpha = alpha;
    node.visible = true;
  }

  /// Drifts, grows and fades every puff, turned to face a camera at [camPos] looking at [camTarget].
  void update(double dt, vm.Vector3 camPos, vm.Vector3 camTarget) {
    if (!node.visible) return;
    // The camera's orientation: its back (+z) points from the target to the eye.
    final back = (camPos - camTarget).normalized();
    final right = vm.Vector3(0, 1, 0).cross(back)..normalize();
    final up = back.cross(right);
    final face = vm.Quaternion.fromRotation(vm.Matrix3.columns(right, up, back));
    var any = false;
    for (var i = 0; i < _max; i++) {
      final p = _slots[i];
      if (p == null) continue;
      p.age += dt;
      if (p.age >= p.life) {
        _slots[i] = null;
        _mesh.setInstanceTransform(i, _hidden);
        continue;
      }
      any = true;
      final k = p.age / p.life;
      p.vel.scale(math.exp(-dt * 1.1));
      // Warm smoke rises; a light breeze carries it off.
      p.vel.y += dt * 0.12;
      p.vel.x += dt * 0.06;
      p.pos.addScaled(p.vel, dt);
      final size = p.size0 + (p.size1 - p.size0) * (1 - math.pow(1 - k, 2));
      final opacity = p.alpha * math.min(1, p.age * 8) * math.pow(1 - k, 1.5);
      final q = face * vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), p.spin + p.age * 0.3);
      _mesh.setInstanceTransform(i, vm.Matrix4.compose(p.pos, q, vm.Vector3.all(size)));
      _mesh.setInstanceColor(i, vm.Vector4(0.72, 0.76, 0.81, opacity.toDouble()));
    }
    if (!any) node.visible = false;
  }

  /// A soft round blob, white in the middle and fading out to nothing.
  static Future<Texture2D> _puffTexture() {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(
      const Rect.fromLTWH(0, 0, 64, 64),
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(32, 32),
          32,
          [const Color(0xFFFFFFFF), const Color(0x99FFFFFF), const Color(0x00FFFFFF)],
          const [0, 0.45, 1],
        ),
    );
    return pictureTexture(rec.endRecording(), 64, 64);
  }
}
