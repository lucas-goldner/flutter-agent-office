// Telling when the 3D office is too much for this computer, to offer the 2D view (/lite) instead. A port
// of framerate.ts.

/// When frames count as slow.
class SlowFramesOptions {
  const SlowFramesOptions({required this.slowMs, required this.spanMs, required this.warmupMs, required this.gapMs});

  /// A frame this long or longer on average (ms) is slow: 50 is under 20 frames a second.
  final double slowMs;

  /// How long frames have to stay that slow (ms of drawing) before it counts.
  final double spanMs;

  /// Not counted at first (ms from the first frame), while the office loads and its shaders compile.
  final double warmupMs;

  /// A frame longer than this (ms) is a gap, not a slow frame: a hidden tab, a stall. It starts the span over.
  final double gapMs;
}

const kSlowFrames = SlowFramesOptions(slowMs: 50, spanMs: 10000, warmupMs: 8000, gapMs: 1000);

/// Watches how long frames take. Once the office has warmed up, frames averaging `slowMs` or more
/// through a whole `spanMs` say the 3D is too slow here, once.
class SlowFrames {
  SlowFrames([this.opts = kSlowFrames]);

  final SlowFramesOptions opts;
  double? _warmUntil;
  double? _start;
  double _total = 0;
  int _count = 0;
  bool _said = false;

  /// A frame drawn at [now], [dt] ms after the one before. True the first time frames have been slow for a whole span.
  bool frame(double now, double dt) {
    if (_said) return false;
    final warm = _warmUntil ??= now + opts.warmupMs;
    if (now < warm) return false;
    if (dt >= opts.gapMs) {
      _start = null;
      return false;
    }
    var start = _start;
    if (start == null) {
      start = _start = now;
      _total = 0;
      _count = 0;
    }
    _total += dt;
    _count++;
    if (now - start < opts.spanMs) return false;
    final slow = _total / _count >= opts.slowMs;
    _start = null;
    _said = slow;
    return slow;
  }
}
