// A floor blown off the building (💣 in the elevator, #126): for the people on it, a flash, a
// cloud of smoke and debris, and the screen shaking for a moment, before they ride the elevator
// down to the next floor. Everyone else just hears about it in a toast.

import 'dart:math' as math;

import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof;
import 'package:vector_math/vector_math.dart' as vm;

/// Whether a new floor list means the floor you're on was just taken off the building.
bool floorBlownUp(String? current, List<FloorInfo> floors) =>
    current != null && current != roof && !floors.any((f) => f.id == current);

class Blast {
  Blast({math.Random? random}) : _rnd = random ?? math.Random();

  final math.Random _rnd;

  /// How long it goes on before the lights go down for the ride, in seconds.
  static const double ride = 1.6;

  /// Seconds since it went off; null when it's over.
  double? _t;

  bool get active => _t != null;
  double get t => _t ?? 0;

  void start() => _t = 0;

  void update(double dt) {
    final t = _t;
    if (t == null) return;
    _t = t + dt < 3 ? t + dt : null;
  }

  /// The white-hot flash over the screen, 0-1: up in a blink, then fading over half a second.
  double get flash {
    final t = _t;
    if (t == null) return 0;
    if (t < 0.06) return t / 0.06;
    return math.max(0, 1 - (t - 0.06) / 0.5);
  }

  /// How hard the camera shakes, in meters: hard at first, dying away.
  double get strength {
    final t = _t;
    if (t == null || t > ride + 0.4) return 0;
    return 0.35 * math.exp(-t * 2.2);
  }

  /// This frame's camera jolt.
  vm.Vector3 shake() {
    final s = strength;
    if (s == 0) return vm.Vector3.zero();
    double r() => (_rnd.nextDouble() * 2 - 1) * s;
    return vm.Vector3(r(), r() * 0.6, r());
  }
}
