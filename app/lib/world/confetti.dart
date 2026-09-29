// Confetti: little paper squares shot up out of a point (or let go from the ceiling), fluttering down
// and settling on whatever is below. All of it is one instanced mesh, so a room full of it is still a
// single draw.
// A port of world/confetti.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'text.dart' show verticalPlane;
import 'toon.dart' show hex, linear;

const _colors = ['#ef476f', '#ffd166', '#06d6a0', '#118ab2', '#f78c6b', '#b388eb', '#5bc0eb', '#ffffff'];
const int kConfettiMax = 5000;
const double _gravity = 9.8;

/// Air slows the bits down after the pop...
const double _drag = 2.5;

/// ...and paper can't fall faster than this (m/s): it flutters.
const double _fall = 1.2;

class _Bit {
  _Bit({
    required this.life,
    required this.pos,
    required this.vel,
    required this.axis,
    required this.angle,
    required this.spin,
    required this.sway,
    required this.swayAt,
  });

  final double life;
  double age = 0;
  final vm.Vector3 pos;
  final vm.Vector3 vel;
  final vm.Vector3 axis;
  double angle;
  final double spin;

  /// How it sways from side to side while falling.
  final double sway;
  final double swayAt;

  /// What it lands on, worked out once it's lower than [look]; NaN until then.
  double ground = double.nan;
  double look = 1.5;
  bool landed = false;
}

/// Where confetti rains over: a rectangle of floor.
typedef ConfettiArea = ({double minX, double maxX, double minZ, double maxZ});

/// Confetti still to come down from the ceiling: [left] bits at [rate] a second.
class _Rain {
  _Rain(this.area, this.from, this.left, this.rate);
  final ConfettiArea area;
  final double Function(double x, double z) from;
  int left;
  final double rate;

  /// A part of a bit carried to the next frame, so a slow rain still comes down.
  double owed = 0;
}

class Confetti {
  /// [groundAt] says how high the surface under (x, z) is, for something falling from y.
  Confetti(this.groundAt, {math.Random? random}) : _rnd = random ?? math.Random() {
    final mat = UnlitMaterial()..doubleSided = true;
    mesh = InstancedMesh(geometry: verticalPlane(0.06, 0.1), material: mat);
    for (var i = 0; i < kConfettiMax; i++) {
      mesh.addInstance(_hidden, color: linear(hex(_colors[i % _colors.length])));
    }
    node = Node(name: 'confetti')
      ..addComponent(InstancedMeshComponent(mesh))
      ..castsShadows = false
      ..frustumCulled = false
      ..visible = false;
  }

  final double Function(double x, double z, double y) groundAt;
  final math.Random _rnd;
  late final InstancedMesh mesh;
  late final Node node;
  final List<_Bit?> _bits = List.filled(kConfettiMax, null);
  int _next = 0;
  int _live = 0;
  final List<_Rain> _rains = [];

  /// Confetti still to rain down (not yet let go).
  int get pending => _rains.fold(0, (n, r) => n + r.left);

  static final vm.Matrix4 _hidden = vm.Matrix4.diagonal3Values(0, 0, 0);

  /// How many bits are in the air or on the floor right now.
  int get count => _live;

  double _r() => _rnd.nextDouble();

  /// Shoots [n] bits up out of (x, y, z); [power] 1 is a party popper, 2 a cannon.
  void burst(double x, double y, double z, [int n = 180, double power = 1]) {
    for (var k = 0; k < n; k++) {
      final a = _r() * math.pi * 2;
      final out = (0.6 + _r() * 2.2) * power;
      _add(
        vm.Vector3(x + (_r() - 0.5) * 0.3, y + _r() * 0.2, z + (_r() - 0.5) * 0.3),
        vm.Vector3(math.cos(a) * out, (4 + _r() * 4) * power, math.sin(a) * out),
        4 + _r() * 3,
        // Looks for what it lands on once it's coming down past here (a burst down on the street is below the floor).
        math.min(1.5, y - 0.8),
      );
    }
  }

  /// Lets [n] bits go all over [area] for [seconds], from [from] (x, z) overhead (the ceiling), to
  /// flutter down on everything and everyone.
  void rain(ConfettiArea area, double n, double seconds, double Function(double x, double z) from) {
    _rains.add(_Rain(area, from, n.round(), n / seconds));
  }

  void _shed(_Rain r, double dt) {
    final due = r.rate * dt + r.owed;
    final n = math.min(r.left, due.floor());
    r.owed = due - n;
    r.left -= n;
    final a = r.area;
    for (var k = 0; k < n; k++) {
      final x = a.minX + _r() * (a.maxX - a.minX);
      final z = a.minZ + _r() * (a.maxZ - a.minZ);
      final y = r.from(x, z) - _r() * 0.3;
      // Knowing roughly what's underneath already (the loft's floor, a stair) keeps it from falling through.
      final below = groundAt(x, z, y);
      final vel = vm.Vector3((_r() - 0.5) * 0.4, -0.2 - _r() * 0.6, (_r() - 0.5) * 0.4);
      // As long as it takes to come down, then a few seconds lying there.
      _add(vm.Vector3(x, y, z), vel, (y - below) / _fall + 3 + _r() * 2.5, below + 1.5);
    }
  }

  void _add(vm.Vector3 pos, vm.Vector3 vel, double life, double look) {
    final i = _next;
    _next = (_next + 1) % kConfettiMax;
    if (_bits[i] == null) _live++;
    _bits[i] = _Bit(
      life: life,
      pos: pos,
      vel: vel,
      axis: vm.Vector3(_r() - 0.5, _r() - 0.5, _r() - 0.5).normalized(),
      angle: _r() * math.pi * 2,
      spin: (_r() < 0.5 ? -1 : 1) * (6 + _r() * 10),
      sway: 0.4 + _r() * 0.6,
      swayAt: _r() * math.pi * 2,
    )..look = look;
    mesh.setInstanceColor(i, linear(hex(_colors[_rnd.nextInt(_colors.length)])));
    node.visible = true;
  }

  void update(double dt) {
    for (final r in _rains) {
      _shed(r, dt);
    }
    _rains.removeWhere((r) => r.left <= 0);
    if (_live == 0) return;
    for (var i = 0; i < kConfettiMax; i++) {
      final b = _bits[i];
      if (b == null) continue;
      b.age += dt;
      if (b.age >= b.life) {
        _bits[i] = null;
        _live--;
        mesh.setInstanceTransform(i, _hidden);
        continue;
      }
      if (!b.landed) {
        final drag = math.exp(-_drag * dt);
        b.vel.x *= drag;
        b.vel.z *= drag;
        if (b.vel.y > 0) {
          b.vel.y = (b.vel.y - _gravity * dt) * drag;
        } else {
          b.vel.y += (-_fall - b.vel.y) * (1 - math.exp(-4 * dt));
        }
        b.pos.addScaled(b.vel, dt);
        // Falling paper drifts side to side.
        if (b.vel.y < 0) {
          b.pos.x += math.sin(b.age * 5 * b.sway + b.swayAt) * b.sway * dt;
          b.pos.z += math.cos(b.age * 4 * b.sway + b.swayAt) * b.sway * dt;
        }
        b.angle += b.spin * dt;
        // Low enough to land: look once at what's underneath (a desk, the counter, the floor).
        if (b.vel.y < 0 && b.ground.isNaN && b.pos.y < b.look) b.ground = groundAt(b.pos.x, b.pos.z, b.pos.y);
        final floor = b.ground.isNaN ? double.negativeInfinity : b.ground + 0.01;
        if (b.pos.y <= floor) {
          b.pos.y = floor;
          b.landed = true;
        }
      }
      // Once down it lies flat, turned whichever way it happened to land.
      final q = b.landed
          ? vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -math.pi / 2) * vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), b.swayAt)
          : vm.Quaternion.axisAngle(b.axis, b.angle);
      // Shrinks away at the end of its life.
      final left = b.life - b.age;
      final s = left < 0.5 ? left / 0.5 : 1.0;
      mesh.setInstanceTransform(i, vm.Matrix4.compose(b.pos, q, vm.Vector3.all(s)));
    }
    if (_live == 0) node.visible = false;
  }
}
