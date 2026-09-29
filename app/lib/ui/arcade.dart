// Screens in the office you play on up close (ui/arcade.ts): [ScreenZoom] glides the camera up to a
// screen and says where it is on the page, and [Arcade] is the boss's monitor, which plays
// Minesweeper (ui/minesweeper.dart). It is all Flutter, so it plays the same in the desktop app.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kMiddleMouseButton, kPrimaryButton, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' hide Material;
import 'package:vector_math/vector_math.dart' as vm;

import '../world/office/office.dart' show Face;
import '../world/text.dart' show pictureTexture;
import 'minesweeper.dart';
import 'modal.dart';
import 'theme.dart';

/// How much of the view (across or down, whichever runs out first) a screen fills while you use it.
const double _fill = 0.8;

/// Glides the camera up to a screen in the office while you use it, and back after, and keeps
/// [rect] on where that screen is on the page, for whatever is laid over it.
class ScreenZoom {
  ScreenZoom(this.screen);

  final Face screen;

  /// 0 is your own view, 1 is right up at the screen. It eases between them.
  double _zoom = 0;

  /// Where the screen is on the page while [update] is told it's on (null otherwise).
  final ValueNotifier<Rect?> rect = ValueNotifier(null);

  /// Anywhere between your view and the screen: your first-person hands would cover it.
  bool get zoomed => _zoom > 0;

  /// Moves [camera] (engine space) toward the screen while [on], and back after. Call it once the
  /// player has placed the camera; returns the camera to draw with.
  PerspectiveCamera update(PerspectiveCamera camera, double dt, Size view, bool on) {
    final want = on ? 1.0 : 0.0;
    if (!on && rect.value != null) rect.value = null;
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
    // The screen's up, so a screen that leans back (the cabinet's) comes out square to the view.
    final up = ((corners[0] + corners[1]) / 2 - center)..normalize();
    // Straight out from the screen, back just far enough that it fills _fill of the view.
    final span = 2 * math.tan(camera.fovRadiansY / 2) * _fill;
    final aspect = view.isEmpty ? 16 / 9 : view.width / view.height;
    final back = math.max(height / span, width / (span * aspect));
    final at = center + normal * back;
    final z = _zoom;
    final pos = camera.position + (at - camera.position) * z;
    final dir = ((camera.target - camera.position).normalized() * (1 - z) - normal * z)..normalize();
    final camUp = (vm.Vector3(0, 1, 0) * (1 - z) + up * z)..normalize();
    final cam = PerspectiveCamera(
      fovRadiansY: camera.fovRadiansY,
      position: pos,
      target: pos + dir,
      up: camUp,
      fovNear: camera.fovNear,
      fovFar: camera.fovFar,
    );
    if (on && !view.isEmpty) {
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

/// Paints [draw] ([w] x [h] units) onto [face]'s texture. Paints never overlap: one asked for while
/// another is on its way goes after it, with whatever is newest by then.
class ScreenTexture {
  ScreenTexture(this.face, this.w, this.h, this.draw, {this.pixels = 1});

  final Face face;
  final double w, h;

  /// Texture pixels per unit.
  final double pixels;
  final void Function(Canvas c) draw;
  bool _busy = false, _again = false;

  void paint() {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(pixels);
    draw(c);
    final pic = rec.endRecording();
    pictureTexture(pic, (w * pixels).round(), (h * pixels).round())
        .then((t) {
          face.material
            ..baseColorTexture = t
            ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
        })
        .catchError((Object _) {})
        .whenComplete(() {
          pic.dispose();
          _busy = false;
          if (_again) {
            _again = false;
            paint();
          }
        });
  }
}

/// A screen laid over its place on the page ([rect]), with its bar underneath: what it is, a tip
/// and the way out. It fades in once the camera has got there.
class ScreenBox extends StatefulWidget {
  const ScreenBox({super.key, required this.rect, required this.screen, required this.bar, this.over});

  final ValueListenable<Rect?> rect;
  final Widget screen;
  final Widget bar;

  /// Laid over the top of the screen (the cabinet's "a worker needs you").
  final Widget? over;

  @override
  State<ScreenBox> createState() => _ScreenBoxState();
}

class _ScreenBoxState extends State<ScreenBox> {
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
            Positioned.fromRect(rect: r, child: widget.screen),
            if (widget.over != null)
              Positioned(
                top: r.top + 12,
                left: r.left,
                width: r.width,
                child: Center(child: Material(type: MaterialType.transparency, child: widget.over)),
              ),
            Positioned(
              top: r.bottom + 10,
              left: 0,
              right: 0,
              child: Center(
                child: Material(type: MaterialType.transparency, child: widget.bar),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// The bar under a screen you're using: its name, a tip, and a button to stop.
Widget screenBar(String name, String tip, String stop, VoidCallback onStop) => Container(
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
      Text(name, style: heavy(14)),
      const SizedBox(width: 12),
      Flexible(child: Text(tip, style: heavy(12, color: Swatch.muted))),
      const SizedBox(width: 12),
      OfficeButton(label: stop, onPressed: onStop),
    ],
  ),
);

/// The boss's monitor, which plays Minesweeper. The monitor shows the board as it was left. Sit down
/// and play, and the camera glides up to the screen while a board you can click is laid exactly
/// over it.
class Arcade {
  Arcade(Face screen) : view = ScreenZoom(screen) {
    _texture = ScreenTexture(screen, msWidth, msHeight, (c) => game.paint(c, idle: true));
    _texture.paint();
  }

  final ScreenZoom view;
  final Minesweeper game = Minesweeper();
  late final ScreenTexture _texture;
  ModalHandle? _modal;
  Timer? _clock;

  /// Bumped whenever the board changes, for the one you play on.
  final ValueNotifier<int> version = ValueNotifier(0);

  /// Anywhere between your view and the monitor: your first-person hands would cover the screen.
  bool get zoomed => view.zoomed;

  bool get playing => _modal != null;

  /// Something changed: the board you play on redraws, and the monitor does once you stop.
  void changed() {
    version.value++;
    if (_modal == null) _texture.paint();
  }

  void play() {
    if (_modal != null) return;
    // A finished game stays up on the monitor until the next player sits down to a fresh one.
    if (game.over) game.reset();
    var last = DateTime.now();
    // The clock only runs while someone's at the monitor.
    _clock = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final now = DateTime.now();
      if (game.tick(now.difference(last).inMicroseconds / 1000)) changed();
      last = now;
    });
    _modal = ModalStack.instance.show(
      (modal) => ScreenBox(
        rect: view.rect,
        screen: _MineBoard(arcade: this),
        bar: screenBar('💣 Minesweeper', 'Click to dig · right-click to flag', '✕ Stop playing', modal.close),
      ),
      backdropCloses: false,
      clear: true,
      onClose: () {
        _modal = null;
        _clock?.cancel();
        game.hover = game.pressed = -1;
        changed();
      },
    );
    changed();
  }

  void stop() => _modal?.close();

  /// Moves [camera] toward the monitor while you play, and back after. Call it once the player has
  /// placed the camera; returns the camera to draw with.
  PerspectiveCamera update(PerspectiveCamera camera, double dt, Size view) =>
      this.view.update(camera, dt, view, _modal != null);
}

/// The board you click, drawn at the size it shows on the page so it stays crisp.
class _MineBoard extends StatefulWidget {
  const _MineBoard({required this.arcade});
  final Arcade arcade;

  @override
  State<_MineBoard> createState() => _MineBoardState();
}

class _MineBoardState extends State<_MineBoard> {
  bool _holding = false;

  Minesweeper get game => widget.arcade.game;

  Offset _spot(Offset local, Size size) => Offset(local.dx * msWidth / size.width, local.dy * msHeight / size.height);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      return MouseRegion(
        onExit: (_) {
          if (_holding) return;
          game.hover = -1;
          widget.arcade.changed();
        },
        child: Listener(
          onPointerDown: (e) {
            final p = _spot(e.localPosition, size);
            final i = game.cellAt(p.dx, p.dy);
            final keys = HardwareKeyboard.instance;
            final primary = e.buttons & kPrimaryButton != 0;
            // Right-click flags, and so do Ctrl- and Shift-click for a trackpad. The middle button chords.
            if (e.buttons & kSecondaryButton != 0 ||
                (primary && (keys.isControlPressed || keys.isShiftPressed))) {
              game.flag(i);
            } else if (e.buttons & kMiddleMouseButton != 0) {
              game.chord(i);
            } else if (primary && game.onFace(p.dx, p.dy)) {
              game.reset();
            } else if (primary) {
              // It digs when you let go, wherever you let go, like the original.
              _holding = true;
              game.pressed = i;
            }
            widget.arcade.changed();
          },
          onPointerHover: (e) => _moved(_spot(e.localPosition, size)),
          onPointerMove: (e) => _moved(_spot(e.localPosition, size)),
          onPointerUp: (e) {
            if (!_holding) return;
            _holding = false;
            final i = game.pressed;
            game.pressed = -1;
            // A click on a number digs around it, once its mines are all flagged.
            if (game.isOpen(i)) {
              game.chord(i);
            } else {
              game.open(i);
            }
            widget.arcade.changed();
          },
          onPointerCancel: (_) {
            _holding = false;
            game.pressed = -1;
            widget.arcade.changed();
          },
          child: ValueListenableBuilder<int>(
            valueListenable: widget.arcade.version,
            builder: (context, _, _) => CustomPaint(size: size, painter: _MinePainter(game, widget.arcade.version.value)),
          ),
        ),
      );
    },
  );

  void _moved(Offset p) {
    final i = game.cellAt(p.dx, p.dy);
    if (i == game.hover) return;
    game.hover = i;
    if (_holding) game.pressed = i;
    widget.arcade.changed();
  }
}

class _MinePainter extends CustomPainter {
  _MinePainter(this.game, this.version);
  final Minesweeper game;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / msWidth, size.height / msHeight);
    game.paint(canvas, idle: false);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MinePainter old) => old.version != version || old.game != game;
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
