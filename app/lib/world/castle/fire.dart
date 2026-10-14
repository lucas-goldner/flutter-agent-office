// Fire: the flames on every torch, brazier, candle and hearth (they flicker in the castle's update),
// and the few real lights among them. A port of world/castle/fire.ts.
//
// The engine has no additive sprites: a flame's glow is a faint see-through ball round it, and a
// "real light" is one of the toon shader's eight pools of lamplight (see the castle's mood).

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../office/geo.dart' show cone, sphere, transformed;
import '../toon.dart' show hex, linear, mesh;
import 'kit.dart';

final math.Random _rng = math.Random();

/// Every flame's cones: the same two shapes, scaled.
final Geometry _outer = transformed(cone(0.45, 1, 8), vm.Matrix4.translationValues(0, 0.5, 0));
final Geometry _inner = transformed(cone(0.25, 0.7, 8), vm.Matrix4.translationValues(0, 0.35, 0));
final UnlitMaterial _flameOut = UnlitMaterial()..baseColorFactor = linear(hex('#ff8c2a'));
final UnlitMaterial _flameIn = UnlitMaterial()..baseColorFactor = linear(hex('#ffe38a'));
final UnlitMaterial _glow = UnlitMaterial()
  ..alphaMode = AlphaMode.blend
  ..baseColorFactor = linear(hex('#ffb45a'), 0.09);

/// A licking flame [size] tall at (x, y, z) in [parent], with a warm glow round it.
void flame(Kit kit, Node parent, double x, double y, double z, double size) {
  final f = Node(name: 'flame')..position = vm.Vector3(x, y, z);
  f.add(Node(mesh: Mesh(_outer, _flameOut))..castsShadows = false);
  f.add(
    Node(mesh: Mesh(_inner, _flameIn))
      ..position = vm.Vector3(0, 0.02, 0)
      ..castsShadows = false,
  );
  f.scale = vm.Vector3.all(size);
  parent.add(f);
  final glow = mesh(sphere(1, 10, 8), _glow, x, y + size * 0.45, z, false)..scale = vm.Vector3.all(size * 1.1);
  parent.add(glow);
  kit.flames.add(Flame(f, glow, size, _rng.nextDouble() * 10));
}

/// A real light at (x, y, z) (in the castle's space), while there are few enough of them.
void fireLight(Kit kit, double x, double y, double z, double power) {
  if (kit.lights.length >= maxLights) return;
  kit.lights.add(FireLight(vm.Vector3(x, y, z), power, _rng.nextDouble() * 10));
}
