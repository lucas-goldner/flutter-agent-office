// Timing laps of the scenic loop (features/cars/laps.ts; see shared scenic.dart): from the chequered
// line across the street in front of the office, all the way round the loop (either way) past each of
// its checkpoints, and back over the line. Crossing it without having been round just starts the clock
// again.

import 'package:office_shared/layout.dart' show Road;
import 'package:office_shared/scenic.dart' show checkpoints, nearLoop;

class LapTimer {
  LapTimer([this.best]);

  /// Your fastest lap so far (seconds), if you've done one.
  double? best;

  /// The last lap you finished: how long it took, whether it was your best, and when (the timer's clock).
  ({double time, bool best, double at})? done;

  /// When the lap you're on started, if you've crossed the line.
  double? _start;
  final Set<int> _passed = {};
  ({double x, double z})? _last;

  /// The car's got to (x, z) at [now] (seconds). Returns the lap's time if that finished one.
  double? update(double x, double z, double now) {
    final was = _last;
    _last = (x: x, z: z);
    if (was == null) return null;
    final at = nearLoop(x, z);
    if (at != null && at.off < 8) {
      for (final (i, d) in checkpoints.indexed) {
        if ((at.d - d).abs() < 12) _passed.add(i);
      }
    }
    // Over the line, on the street, one way or the other (not jumped across it).
    final street = z > Road.minZ - 1 && z < Road.maxZ + 1;
    if (!street || (was.x < 0) == (x < 0) || (x - was.x).abs() > 10) return null;
    double? lap;
    final start = _start;
    if (start != null && _passed.length == checkpoints.length) {
      lap = now - start;
      final isBest = best == null || lap < best!;
      if (isBest) best = lap;
      done = (time: lap, best: isBest, at: now);
    }
    _start = now;
    _passed.clear();
    return lap;
  }

  /// How long you've been on this lap, once you're out on the loop (null till then).
  double? running(double now) => _start != null && _passed.isNotEmpty ? now - _start! : null;

  /// Out of the car: the lap you were on doesn't count.
  void reset() {
    _start = null;
    _passed.clear();
    _last = null;
  }
}

/// A lap's time as m:ss.t.
String lapTime(double s) {
  final tenths = (s * 10).round();
  final m = tenths ~/ 600;
  final rest = (tenths - m * 600) / 10;
  return '$m:${rest < 10 ? '0' : ''}${rest.toStringAsFixed(1)}';
}
