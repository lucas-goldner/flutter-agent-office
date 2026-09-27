// DEADFALL on the boss's monitor (ui/arcade.ts): the three.js survival game, from its GitHub Pages
// build. It draws at a fixed 960×540 (scaled up to the monitor) on medium quality and at most
// 60 fps, so it costs the same whatever the window size and leaves the GPU room for the office.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart' hide Material;
import 'package:vector_math/vector_math.dart' as vm;

import '../interop/game_frame.dart';
import '../world/office/office.dart' show Face;
import '../world/text.dart' show pictureTexture;
import 'modal.dart';
import 'theme.dart';

const String _gameSrc = 'https://webdevcody.github.io/deadfall/?quality=medium&maxfps=60';
const int _gameWidth = 960, _gameHeight = 540;

/// How much of the view (across or down, whichever runs out first) the monitor fills while you play.
const double _fill = 0.8;

/// The boss's monitor. It shows a title card until you sit down and play. Then the camera glides up
/// to it and the game loads into a frame laid exactly over the screen's projected rectangle.
/// Stopping throws the frame away, so the game costs nothing while nobody's playing.
class Arcade {
  Arcade(this.screen) {
    _titleCard().then((t) {
      screen.material
        ..baseColorTexture = t
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
    });
  }

  final Face screen;

  /// 0 is your own view, 1 is right up at the monitor. It eases between them.
  double _zoom = 0;
  ModalHandle? _modal;

  /// Where the screen is on the page while you play (null otherwise).
  final ValueNotifier<Rect?> rect = ValueNotifier(null);

  /// Right up at the monitor and holding still: the office around it can be redrawn less often.
  bool get settled => _zoom == 1;

  /// Anywhere between your view and the monitor: your first-person hands would cover the screen.
  bool get zoomed => _zoom > 0;

  bool get playing => _modal != null;

  void play() {
    if (_modal != null) return;
    _modal = ModalStack.instance.show(
      (modal) => _ArcadeBox(modal: modal, rect: rect),
      backdropCloses: false,
      clear: true,
      onClose: () {
        _modal = null;
        rect.value = null;
      },
    );
  }

  void stop() => _modal?.close();

  /// Moves [camera] (engine space) toward the monitor while you play, and back after. Call it once
  /// the player has placed the camera; returns the camera to draw with.
  PerspectiveCamera update(PerspectiveCamera camera, double dt, Size view) {
    final want = _modal != null ? 1.0 : 0.0;
    if (_zoom == want) {
      if (want == 0) return camera;
    } else {
      _zoom += (want - _zoom) * math.min(1, dt * 8);
      if ((want - _zoom).abs() < 0.002) _zoom = want;
    }
    final g = screen.node.globalTransform;
    final center = g.transform3(vm.Vector3.zero());
    final corners = [
      for (final (x, y) in [(-1, 1), (1, 1), (1, -1), (-1, -1)])
        g.transform3(vm.Vector3(x * screen.width / 2, y * screen.height / 2, 0)),
    ];
    final width = corners[0].distanceTo(corners[1]), height = corners[1].distanceTo(corners[2]);
    final normal = (g.transform3(vm.Vector3(0, 0, 1)) - center)..normalize();
    // Straight out from the screen, back just far enough that it fills _fill of the view.
    final span = 2 * math.tan(camera.fovRadiansY / 2) * _fill;
    final aspect = view.isEmpty ? 16 / 9 : view.width / view.height;
    final back = math.max(height / span, width / (span * aspect));
    final at = center + normal * back;
    final z = _zoom;
    final pos = camera.position + (at - camera.position) * z;
    final dir = ((camera.target - camera.position).normalized() * (1 - z) - normal * z)..normalize();
    final cam = PerspectiveCamera(
      fovRadiansY: camera.fovRadiansY,
      position: pos,
      target: pos + dir,
      fovNear: camera.fovNear,
      fovFar: camera.fovFar,
    );
    if (_modal != null && !view.isEmpty) {
      final pts = [for (final c in corners) cam.worldToScreen(c, view)];
      if (pts.every((p) => p != null)) {
        final xs = pts.map((p) => p!.dx), ys = pts.map((p) => p!.dy);
        final r = Rect.fromLTRB(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
        final old = rect.value;
        bool moved(double a, double b) => (a - b).abs() > 0.5;
        if (old == null ||
            moved(old.left, r.left) ||
            moved(old.top, r.top) ||
            moved(old.right, r.right) ||
            moved(old.bottom, r.bottom)) {
          rect.value = r;
        }
      }
    }
    return cam;
  }
}

/// The game over the monitor, with its bar underneath: what it is, a tip and the way out.
class _ArcadeBox extends StatefulWidget {
  const _ArcadeBox({required this.modal, required this.rect});
  final ModalHandle modal;
  final ValueListenable<Rect?> rect;

  @override
  State<_ArcadeBox> createState() => _ArcadeBoxState();
}

class _ArcadeBoxState extends State<_ArcadeBox> {
  bool _shown = false;
  late final Timer _fade = Timer(const Duration(milliseconds: 300), () => setState(() => _shown = true));

  @override
  void initState() {
    super.initState();
    _fade;
  }

  @override
  void dispose() {
    _fade.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Rect?>(
    valueListenable: widget.rect,
    builder: (context, r, _) {
      if (r == null) return const SizedBox.expand();
      return AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: Stack(
          children: [
            Positioned.fromRect(
              rect: r,
              child: const GameFrame(src: _gameSrc, title: 'DEADFALL', width: _gameWidth, height: _gameHeight),
            ),
            Positioned(
              top: r.bottom + 10,
              left: 0,
              right: 0,
              child: Center(
                child: Material(type: MaterialType.transparency, child: _bar()),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _bar() => Container(
    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
    decoration: BoxDecoration(
      color: Swatch.paper,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Swatch.ink, width: kBorder),
      boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('🌲 DEADFALL', style: heavy(14)),
        const SizedBox(width: 12),
        Text('Esc lets go of the mouse', style: heavy(12, color: Swatch.muted)),
        const SizedBox(width: 12),
        OfficeButton(label: '✕ Stop playing', onPressed: widget.modal.close),
      ],
    ),
  );
}

/// What the monitor shows while nobody's playing: misty old-growth forest at dusk.
Future<Texture2D> _titleCard() {
  const w = _gameWidth, h = _gameHeight;
  final rec = ui.PictureRecorder();
  final g = Canvas(rec);
  g.drawRect(
    const Rect.fromLTWH(0, 0, 960, 540),
    Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        const Offset(0, 540),
        const [Color(0xFF1D2B33), Color(0xFF6D7F79), Color(0xFF2C3A2E)],
        const [0, 0.6, 1],
      ),
  );
  // Rows of conifers, darker the nearer they are.
  for (final (row, color, size) in const [
    (330.0, 0xFF3D4D45, 0.7),
    (420.0, 0xFF26332B, 1.0),
    (540.0, 0xFF121A15, 1.4),
  ]) {
    final paint = Paint()..color = Color(color);
    for (var x = -20.0; x < w + 40; x += 46 * size) {
      // As the old client's JS `%`, which keeps the sign.
      final tall = (150 + (x * 7919).remainder(90)) * size;
      g.drawPath(
        Path()
          ..moveTo(x, row)
          ..lineTo(x + 22 * size, row - tall)
          ..lineTo(x + 44 * size, row)
          ..close(),
        paint,
      );
    }
  }
  void text(String s, double size, FontWeight weight, double baseline) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: kFont,
          fontFamilyFallback: kFallback,
          fontSize: size,
          fontWeight: weight,
          color: const Color(0xFFF1EDE4),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(g, Offset((w - tp.width) / 2, baseline - tp.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
  }

  text('DEADFALL', 110, FontWeight.w900, 250);
  text('Sit in the boss’s chair and press E to play', 30, FontWeight.w800, 310);
  final picture = rec.endRecording();
  return pictureTexture(picture, w, h).whenComplete(picture.dispose);
}

/// A SceneView that the page ticks itself, so it can draw the office on only some frames: every
/// [every]() frames (1 draws them all). The frame logic ([onTick]) still runs on every frame.
class FrameSkipSceneView extends StatefulWidget {
  const FrameSkipSceneView(
    this.scene, {
    super.key,
    required this.onTick,
    required this.viewsBuilder,
    required this.every,
  });

  final Scene scene;
  final void Function(Duration elapsed, double dt) onTick;
  final SceneViewsBuilder viewsBuilder;
  final int Function() every;

  @override
  State<FrameSkipSceneView> createState() => _FrameSkipSceneViewState();
}

class _FrameSkipSceneViewState extends State<FrameSkipSceneView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  int _frames = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    widget.onTick(elapsed, dt);
    final n = widget.every();
    _frames = n > 1 ? _frames + 1 : 0;
    // Rebuilding the SceneView is what repaints it when it doesn't tick itself.
    if (_frames % math.max(1, n) == 0) setState(() {});
  }

  @override
  Widget build(BuildContext context) => SceneView(widget.scene, autoTick: false, viewsBuilder: widget.viewsBuilder);
}
