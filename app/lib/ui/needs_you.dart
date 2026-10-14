// The banner under the top bar while a worker needs you (features/needsyou/ui.ts): who, what it's asking
// and for how long, and a click (or N) away from its desk; ✕ puts it away until someone else asks. The edge
// of the screen flashes red when one starts asking.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../needs_you_logic.dart';
import 'hud_parts.dart' show KeyCap;
import 'theme.dart';

class NeedsYouBanner extends StatefulWidget {
  const NeedsYouBanner({super.key, required this.text, required this.onGo, required this.onHide});

  final ValueListenable<BannerText?> text;

  /// To that worker's desk.
  final ValueChanged<String> onGo;

  /// Put away until someone else needs you.
  final VoidCallback onHide;

  @override
  State<NeedsYouBanner> createState() => _NeedsYouBannerState();
}

class _NeedsYouBannerState extends State<NeedsYouBanner> with TickerProviderStateMixin {
  /// The ring spreading out from it, and the 🙋 waving.
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    widget.text.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.text.removeListener(_changed);
    _ring.dispose();
    _wave.dispose();
    super.dispose();
  }

  void _changed() {
    final still = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    if (widget.text.value != null && !still) {
      if (!_ring.isAnimating) _ring.repeat();
      if (!_wave.isAnimating) _wave.repeat();
    } else {
      _ring.stop();
      _wave.stop();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.text.value;
    if (t == null) return const SizedBox.shrink();
    final white = heavy(17, color: Colors.white, weight: FontWeight.w900);
    return Semantics(
      liveRegion: true,
      child: AnimatedBuilder(
        animation: _ring,
        builder: (context, child) => Container(
          constraints: BoxConstraints(maxWidth: math.min(640, MediaQuery.sizeOf(context).width - 24)),
          decoration: BoxDecoration(
            color: Swatch.bad,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Swatch.ink, width: kBorder),
            boxShadow: [
              const BoxShadow(color: Swatch.ink, offset: Offset(0, 4)),
              BoxShadow(
                color: Swatch.bad.withValues(alpha: 0.75 * (1 - _ring.value)),
                spreadRadius: 16 * _ring.value,
              ),
            ],
          ),
          child: child,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: Tooltip(
                    message: "Go to ${t.title.replaceFirst(RegExp(r' needs you$'), '')}'s desk (N)",
                    child: InkWell(
                      key: const ValueKey('needs-you-go'),
                      borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                      onTap: () => widget.onGo(t.id),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AnimatedBuilder(
                              animation: _wave,
                              builder: (context, child) => Transform.rotate(
                                angle: _waveAngle(_wave.value),
                                alignment: const Alignment(0, 0.8),
                                child: child,
                              ),
                              child: const Text('🙋', style: TextStyle(fontSize: 26, height: 1)),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.title, style: white, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  if (t.detail.isNotEmpty)
                                    Text(
                                      t.detail,
                                      style: heavy(13, color: Colors.white, weight: FontWeight.w700),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                            if (t.more.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(color: Swatch.ink, borderRadius: BorderRadius.circular(999)),
                                child: Text(
                                  t.more,
                                  style: heavy(12, color: Colors.white, weight: FontWeight.w900),
                                ),
                              ),
                            ],
                            const SizedBox(width: 10),
                            const KeyCap('N'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Container(width: 2, color: Swatch.ink.withValues(alpha: 0.35)),
                Tooltip(
                  message: 'Hide until another worker needs you',
                  child: InkWell(
                    key: const ValueKey('needs-you-hide'),
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
                    onTap: widget.onHide,
                    child: SizedBox(
                      width: 34,
                      child: Center(
                        child: Text(
                          '✕',
                          style: heavy(13, color: Colors.white, weight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The 🙋's wave: still, then over to one side and the other, and still again.
  static double _waveAngle(double v) {
    const deg = math.pi / 180;
    if (v < 0.15) return -14 * deg * (v / 0.15);
    if (v < 0.30) return (-14 + 26 * (v - 0.15) / 0.15) * deg;
    if (v < 0.45) return (12 - 26 * (v - 0.30) / 0.15) * deg;
    if (v < 0.60) return -14 * deg * (1 - (v - 0.45) / 0.15);
    return 0;
  }
}

/// The red flash round the edge of the screen when a worker starts asking: three pulses over 2.4 s (one
/// fade with less motion). [pulse] is bumped to start one.
class NeedsYouFlash extends StatefulWidget {
  const NeedsYouFlash({super.key, required this.pulse});
  final ValueListenable<int> pulse;

  @override
  State<NeedsYouFlash> createState() => _NeedsYouFlashState();
}

class _NeedsYouFlashState extends State<NeedsYouFlash> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  bool _calm = false;

  @override
  void initState() {
    super.initState();
    widget.pulse.addListener(_go);
  }

  @override
  void dispose() {
    widget.pulse.removeListener(_go);
    _c.dispose();
    super.dispose();
  }

  void _go() {
    _calm = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    _c.duration = Duration(milliseconds: _calm ? 1600 : 2400);
    _c.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final o = _c.isAnimating ? needsYouFlashOpacity(_c.value, calm: _calm) : 0.0;
        if (o <= 0) return const SizedBox.shrink();
        return Opacity(
          opacity: o.clamp(0.0, 1.0),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              border: Border.fromBorderSide(BorderSide(color: Swatch.bad, width: 8)),
              gradient: RadialGradient(
                radius: 1.1,
                colors: [Color(0x00EF476F), Color(0x00EF476F), Color(0xCCEF476F)],
                stops: [0, 0.6, 1],
              ),
            ),
            child: SizedBox.expand(),
          ),
        );
      },
    ),
  );
}

/// The keyframes: 0 → 1 at 12%, .25 at 29%, 1 at 46%, .25 at 63%, 1 at 80%, 0 at the end.
double needsYouFlashOpacity(double v, {bool calm = false}) {
  if (calm) return 1 - v;
  const stops = [(0.0, 0.0), (0.12, 1.0), (0.29, 0.25), (0.46, 1.0), (0.63, 0.25), (0.80, 1.0), (1.0, 0.0)];
  for (var i = 1; i < stops.length; i++) {
    final (a, x) = stops[i - 1];
    final (b, y) = stops[i];
    if (v <= b) return x + (y - x) * ((v - a) / (b - a));
  }
  return 0;
}
