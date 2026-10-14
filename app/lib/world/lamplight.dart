// Indoors the light the toon shading takes as its sun comes from the lamps overhead, not the street's
// sun: a port of features/lamplight (#219). The office is lit as if it had no roof, so the sun lit the
// walls from angles nobody could see. Indoors it swings round to nearly straight down, and once the
// lamps are on it's warm and at least as bright as they are.
//
// Upstream also stops the outside walls taking shadows indoors; this port has no shadow maps (the toon
// shader is lit by uniforms alone), so there's nothing to turn off there.

import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import 'sky_model.dart' show Rgb;

/// Where the indoor light comes from (nearly straight down, a little off so walls aren't side-on to it),
/// and how bright and warm it is once the lamps are on.
abstract final class IndoorLight {
  static final vm.Vector3 dir = vm.Vector3(0.22, 1, 0.14)..normalize();
  static const double lamp = 0.7;
  static final Rgb color = Rgb.hex(0xffe2b8);
}

class Lamplight {
  /// 0 outdoors to 1 indoors, eased as you come in or go out.
  double indoorness = 0;

  /// After the sky's had its say: eases [indoorness] toward [inside] over [dt] and bends the sky's
  /// light ([dir], [color], [intensity], as the sky gave them) toward the lamps' by it. [lampsOn] is
  /// the sky's 0-1. Returns the light to use.
  ({vm.Vector3 dir, Rgb color, double intensity}) apply({
    required bool inside,
    required double dt,
    required vm.Vector3 dir,
    required Rgb color,
    required double intensity,
    required double lampsOn,
  }) {
    indoorness += ((inside ? 1 : 0) - indoorness) * (1 - math.exp(-dt * 3));
    if (indoorness <= 0.001) return (dir: dir, color: color, intensity: intensity);
    final from = dir.normalized();
    final to = (from + (IndoorLight.dir - from) * indoorness)..normalize();
    var c = color, i = intensity;
    final lamp = IndoorLight.lamp * lampsOn;
    if (lamp > i) {
      c = c.lerp(IndoorLight.color, indoorness * math.min(1, (lamp - i) / lamp));
      i += (lamp - i) * indoorness;
    }
    return (dir: to, color: c, intensity: i);
  }
}
