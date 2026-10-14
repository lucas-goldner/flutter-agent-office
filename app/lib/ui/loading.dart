// The loading screen (#177): a port of ui/loading.ts. A card with the office's name, a hopping paw, a bar
// and a line saying what it's waiting on, up over everything until the office is ready to be seen, or
// until [loadingCap] goes by with nothing happening; it never comes back (a reconnect or a ride to
// another floor keeps the office on screen as it is). The bar counts the model files (world/models.dart)
// and the steps it's given.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../world/models.dart' show ModelsProgress;
import 'theme.dart';

/// Longest the loading screen stays up with nothing happening: a slow download that keeps coming in keeps
/// it up (the world isn't built without it), but a stalled one, an office that doesn't answer or a page
/// that broke on the way never keeps you out.
const Duration loadingCap = Duration(seconds: 8);

/// Something the loading screen waits on, and what it says while it does.
typedef LoadingStep = ({String say, Future<void> done});

enum GateWhy { ready, cap }

/// When the loading screen can come down: once every step it's given has settled (one that fails counts),
/// or once [cap] goes by without a sign of life (see [stillGoing]), whichever comes first. [_release] is
/// called once at most, and nothing after that changes anything.
class LoadingGate {
  LoadingGate(this._release, [this.cap = loadingCap]) {
    _timer = Timer(cap, () => _open(GateWhy.cap));
  }

  final void Function(GateWhy why) _release;
  final Duration cap;
  bool _released = false;
  Timer? _timer;

  bool get released => _released;

  /// What to wait for, on top of the cap. Given once.
  void until(List<Future<void>> steps) {
    Future.wait([for (final s in steps) s.then((_) {}, onError: (Object _) {})]).then((_) => _open(GateWhy.ready));
  }

  /// Something's still happening (more of a file came in, a step settled): the cap starts over from now.
  void stillGoing() {
    if (_released) return;
    _timer?.cancel();
    _timer = Timer(cap, () => _open(GateWhy.cap));
  }

  void _open(GateWhy why) {
    if (_released) return;
    _released = true;
    _timer?.cancel();
    _release(why);
  }
}

/// What the screen shows: how full the bar is (0-1, never going back), what it says, and whether it's gone.
typedef LoadingView = ({double fill, String say, bool gone});

/// The loading screen's state: watches the model files (from [watchModels]) and the steps it waits on.
/// Make it before anything is loaded.
class Loading {
  Loading(VoidCallback Function(void Function(ModelsProgress) fn) watchModels, {Duration cap = loadingCap}) {
    _gate = LoadingGate((why) {
      if (why == GateWhy.cap) {
        final waiting = [
          for (final s in _steps)
            if (!s.settled) s.step.say,
          if (_files.done < _files.asked) '${_files.asked - _files.done} of ${_files.asked} model files',
        ];
        debugPrint(
          'The office went ${cap.inSeconds} s with nothing happening, so in you go anyway. '
          'Still waiting on: ${waiting.join('; ')}',
        );
      }
      _stopWatching?.call();
      _fillTo(1);
      view.value = (fill: _shown, say: view.value.say, gone: true);
    }, cap);
    _follow(_steps.first);
    _stopWatching = watchModels((p) {
      _files = p;
      _gate.stillGoing();
      _paint();
    });
  }

  late final LoadingGate _gate;
  VoidCallback? _stopWatching;
  ModelsProgress _files = (asked: 0, done: 0);
  final Completer<void> _frame = Completer();
  late final List<({LoadingStep step, bool settled})> _steps = [
    (step: (say: 'Loading the office', done: _frame.future), settled: false),
  ];
  bool _given = false;
  double _shown = 0;

  final ValueNotifier<LoadingView> view = ValueNotifier((fill: 0, say: 'Loading the office', gone: false));

  bool get gone => view.value.gone;

  /// The office drew a frame. The first one is waited for on every visit; the rest cost a check each.
  void drew() {
    if (!_frame.isCompleted) _frame.complete();
  }

  /// What else to wait for besides the first frame, said in this order while it's waited for. Given once.
  void until(List<LoadingStep> more) {
    if (_given) return;
    _given = true;
    for (final step in more) {
      _steps.add((step: step, settled: false));
      _follow(_steps.last);
    }
    _paint();
    _gate.until([for (final s in _steps) s.step.done]);
  }

  void _follow(({LoadingStep step, bool settled}) s) {
    void settle() {
      final i = _steps.indexOf(s);
      if (i >= 0) _steps[i] = (step: s.step, settled: true);
      _gate.stillGoing();
      _paint();
    }

    s.step.done.then((_) => settle(), onError: (Object _) => settle());
  }

  void _fillTo(double part) => _shown = math.max(_shown, part);

  void _paint() {
    if (gone) return;
    final settled = _steps.where((s) => s.settled).length;
    _fillTo((_files.done + settled) / (_files.asked + _steps.length));
    // Files still coming in before the office is built, then whichever step is next.
    final unpacking = !_given && _files.done < _files.asked;
    final next = _steps.where((s) => !s.settled).firstOrNull;
    final say = unpacking ? 'Unpacking the office' : (next?.step.say ?? 'Opening the doors');
    view.value = (fill: _shown, say: say, gone: false);
  }
}

/// The screen itself, over everything while [loading] is up; it fades out and stays out once it's gone.
class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key, required this.loading});
  final Loading loading;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<LoadingView>(
    valueListenable: loading.view,
    builder: (context, v, _) => IgnorePointer(
      ignoring: v.gone,
      child: AnimatedOpacity(
        opacity: v.gone ? 0 : 1,
        duration: const Duration(milliseconds: 350),
        child: ColoredBox(
          color: Swatch.sky,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                width: 320,
                padding: const EdgeInsets.fromLTRB(26, 22, 26, 20),
                decoration: BoxDecoration(
                  color: Swatch.paper,
                  border: Border.all(color: Swatch.ink, width: kBorder),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(4, 4))],
                ),
                child: Semantics(
                  liveRegion: true,
                  label: v.say,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _Paw(),
                      const SizedBox(height: 12),
                      Text('Agent Office', style: heavy(26, weight: FontWeight.w900)),
                      const SizedBox(height: 14),
                      _Bar(fill: v.fill),
                      const SizedBox(height: 12),
                      Text(v.say, style: heavy(14, color: Swatch.muted)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fill});
  final double fill;

  @override
  Widget build(BuildContext context) => Container(
    height: 18,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: Swatch.ink, width: kBorder),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: AnimatedFractionallySizedBox(
        duration: const Duration(milliseconds: 300),
        widthFactor: fill.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(color: Swatch.accent, borderRadius: BorderRadius.circular(999)),
        ),
      ),
    ),
  );
}

/// A paw that hops: squashed on landing, up and tipped over at the top, its shadow shrinking as it goes up.
class _Paw extends StatefulWidget {
  const _Paw();

  @override
  State<_Paw> createState() => _PawState();
}

class _PawState extends State<_Paw> with SingleTickerProviderStateMixin {
  late final AnimationController _hop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _hop.stop();
    } else if (!_hop.isAnimating) {
      _hop.repeat();
    }
  }

  @override
  void dispose() {
    _hop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _hop,
    builder: (context, _) {
      final t = _hop.value;
      // Up and back down through the middle of the beat, squashed at either end of it.
      final up = t > 0.2 && t < 0.8 ? math.sin((t - 0.2) / 0.6 * math.pi) : 0.0;
      final squash = t < 0.2 ? 1 - t / 0.2 : (t > 0.8 ? (t - 0.8) / 0.2 : 0.0);
      return Column(
        children: [
          Transform.translate(
            offset: Offset(0, -12 * up),
            child: Transform.rotate(
              angle: -8 * math.pi / 180 * up,
              alignment: Alignment.bottomCenter,
              child: Transform.scale(
                scaleX: 1 + 0.1 * squash,
                scaleY: 1 - 0.1 * squash,
                alignment: Alignment.bottomCenter,
                child: const SizedBox(width: 54, height: 54, child: CustomPaint(painter: _PawPainter())),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Opacity(
            opacity: 1 - 0.4 * up,
            child: Transform.scale(
              scaleX: 1 - 0.4 * up,
              child: Container(
                width: 38,
                height: 7,
                decoration: BoxDecoration(color: const Color(0x2E2B2D42), borderRadius: BorderRadius.circular(999)),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// The paw in index.html's SVG (64 x 64): the pad and four toes, in the accent with an ink outline.
class _PawPainter extends CustomPainter {
  const _PawPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64, size.height / 64);
    final pad = Path()
      ..moveTo(32, 31)
      ..cubicTo(40, 31, 50, 40, 50, 48)
      ..cubicTo(50, 54, 45, 56, 40, 55)
      ..cubicTo(37, 54.5, 35, 53.5, 32, 53.5)
      ..cubicTo(29, 53.5, 27, 54.5, 24, 55)
      ..cubicTo(19, 56, 14, 54, 14, 48)
      ..cubicTo(14, 40, 24, 31, 32, 31)
      ..close();
    final fill = Paint()..color = Swatch.accent;
    final line = Paint()
      ..color = Swatch.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..drawPath(pad, fill)
      ..drawPath(pad, line);
    for (final (cx, cy, rx, ry, deg) in const [
      (11.5, 31.0, 5.5, 7.5, -24.0),
      (24.0, 17.5, 6.0, 8.0, -8.0),
      (40.0, 17.5, 6.0, 8.0, 8.0),
      (52.5, 31.0, 5.5, 7.5, 24.0),
    ]) {
      canvas
        ..save()
        ..translate(cx, cy)
        ..rotate(deg * math.pi / 180);
      final r = Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2);
      canvas
        ..drawOval(r, fill)
        ..drawOval(r, line)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_PawPainter old) => false;
}
