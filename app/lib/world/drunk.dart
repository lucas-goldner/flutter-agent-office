// How the world looks after a few drinks at the rooftop bar (see booze.dart): a port of drunk.ts,
// and of the drunk parts of player.ts.
//
// The old client drew the frame into a texture and put it on the screen through a shader that
// doubled, smeared and rippled it. Here the scene is a Flutter widget, so [DrunkVision] does what a
// widget can do cheaply: the frame breathes in and out, blurs, warms up and oversaturates, and
// darkens round the edges. The view itself rolls and sways and your feet wander off to one side
// ([drunkSway], [drunkStagger], used by PlayerController). Sober, it all costs nothing.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// How the camera sways, [drunk] (0–1.3) at [t] seconds: radians of roll (about the view), pitch
/// and yaw on top of wherever you're looking.
({double roll, double pitch, double yaw}) drunkSway(double drunk, double t) {
  if (drunk <= 0) return (roll: 0, pitch: 0, yaw: 0);
  return (
    roll: drunk * (0.07 * math.sin(t * 0.9) + 0.025 * math.sin(t * 2.3 + 1)),
    pitch: drunk * 0.03 * math.sin(t * 0.7 + 2),
    yaw: drunk * 0.04 * math.sin(t * 0.55 + 4),
  );
}

/// How far (radians) your feet wander off the way you meant to walk, [drunk] at [t] seconds.
double drunkStagger(double drunk, double t) =>
    drunk <= 0 ? 0 : drunk * (0.4 * math.sin(t * 1.6) + 0.22 * math.sin(t * 3.7 + 1));

/// What the screen does, [amount] drunk (see Booze.amount) at [t] seconds; [motion] false holds it still.
class DrunkLook {
  const DrunkLook({
    required this.blur,
    required this.scale,
    required this.dx,
    required this.dy,
    required this.warmth,
    required this.vignette,
  });

  /// Gaussian blur sigma, in logical pixels.
  final double blur;

  /// The room breathing in and out.
  final double scale;

  /// A slow drift of the whole frame, as a fraction of its size.
  final double dx;
  final double dy;

  /// 0–1: how far toward warm and oversaturated.
  final double warmth;

  /// 0–1: how dark round the edges.
  final double vignette;

  static const DrunkLook sober = DrunkLook(blur: 0, scale: 1, dx: 0, dy: 0, warmth: 0, vignette: 0);

  bool get isSober => blur == 0 && warmth == 0;

  factory DrunkLook.at(double amount, double t, {bool motion = true}) {
    if (amount <= 0.01) return sober;
    final a = amount.clamp(0.0, 1.6);
    final k = math.min(a, 1.0);
    final m = motion ? t : 0.0;
    return DrunkLook(
      blur: 0.6 + 1.6 * a,
      scale: 1 + 0.03 * a * (0.5 + 0.5 * math.sin(m * 0.8)),
      dx: math.sin(m * 0.7 + 1) * (0.002 + 0.004 * a) * k,
      dy: 0.45 * math.cos(m * 0.53) * (0.002 + 0.004 * a) * k,
      warmth: k,
      vignette: 0.6 * k,
    );
  }
}

/// The colour matrix for [warmth]: a little oversaturated and warm, like drunk.ts's grade.
List<double> drunkColorMatrix(double warmth) {
  final k = warmth.clamp(0.0, 1.0);
  final s = 1 + 0.4 * k;
  const lr = 0.299, lg = 0.587, lb = 0.114;
  final r = 1 + 0.08 * k, g = 1 - 0.02 * k, b = 1 - 0.1 * k;
  List<double> row(double gain, double self, int i) {
    final l = [lr, lg, lb];
    return [for (var j = 0; j < 3; j++) gain * ((1 - s) * l[j] + (j == i ? s : 0)), 0, 0];
  }

  return [...row(r, s, 0), ...row(g, s, 1), ...row(b, s, 2), 0, 0, 0, 1, 0];
}

/// Puts [child] (the scene) on the screen through [look]: nothing at all while sober. The scene
/// keeps its state across the switch (a global key moves it rather than building it again).
class DrunkVision extends StatefulWidget {
  const DrunkVision({super.key, required this.look, required this.child});

  final ValueListenable<DrunkLook> look;
  final Widget child;

  @override
  State<DrunkVision> createState() => _DrunkVisionState();
}

class _DrunkVisionState extends State<DrunkVision> {
  final GlobalKey _scene = GlobalKey();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DrunkLook>(
    valueListenable: widget.look,
    child: KeyedSubtree(key: _scene, child: widget.child),
    builder: (context, l, child) {
      if (l.isSober) return child!;
      return LayoutBuilder(
        builder: (context, box) => Stack(
          fit: StackFit.expand,
          children: [
            ColorFiltered(
              colorFilter: ColorFilter.matrix(drunkColorMatrix(l.warmth)),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: l.blur, sigmaY: l.blur, tileMode: TileMode.clamp),
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.translationValues(l.dx * box.maxWidth, l.dy * box.maxHeight, 0)
                    ..multiply(Matrix4.diagonal3Values(l.scale, l.scale, 1)),
                  child: child,
                ),
              ),
            ),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.9,
                    colors: [const Color(0x00000000), Color.fromRGBO(0, 0, 0, l.vignette)],
                    stops: const [0.55, 1],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
