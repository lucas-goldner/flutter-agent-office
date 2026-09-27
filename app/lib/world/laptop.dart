// A worker's laptop: a lid that hinges open, and the worker's live terminal on its screen. A port of
// the Laptop class in world/laptop.ts; the screen is laptop_screen.dart's painter, streamed onto
// the lid with a WidgetComponent and repainted less often the further away the camera is.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../state/screen_state.dart';
import 'geo.dart' show euler;
import 'laptop_screen.dart';
import 'leaving.dart' show LeavingLaptop;
import 'text.dart' show verticalPlane;
import 'toon.dart';

class Laptop implements LeavingLaptop {
  Laptop() {
    final shell = toon(hex('#c9ced6'));
    final dark = toon(hex('#2b2d42'));
    // Base with keyboard
    root.add(mesh(roundedBox(0.78, 0.035, 0.52, 0.04), shell, 0, 0.018, 0.02));
    root.add(mesh(CuboidGeometry(vm.Vector3(0.66, 0.006, 0.24)), dark, 0, 0.037, 0.0, false));
    root.add(mesh(CuboidGeometry(vm.Vector3(0.2, 0.004, 0.11)), toon(hex('#aab1bb')), 0, 0.037, 0.19, false));
    // Lid, hinged along the back edge
    _lid.position = vm.Vector3(0, 0.035, -0.24);
    root.add(_lid);
    final lidShell = mesh(roundedBox(0.78, 0.025, 0.5, 0.04), shell, 0, 0.25, 0)..rotation = euler(math.pi / 2, 0);
    _lid.add(lidShell);
    final screenMat = UnlitMaterial();
    final screen = Node(name: 'screen')
      ..position = vm.Vector3(0, 0.25, 0.014)
      ..castsShadows = false
      ..addComponent(
        WidgetComponent(
          size: kLaptopScreenSize,
          pixelRatio: 0.75,
          geometry: verticalPlane(0.72, 0.46),
          material: screenMat,
          update: WidgetUpdatePolicy.manual,
          input: WidgetInput.manual,
          child: ValueListenableBuilder<_Frame>(
            valueListenable: _frame,
            builder: (context, f, _) => LaptopScreen(screen: f.screen, placeholder: f.placeholder),
          ),
        ),
      );
    _widget = screen.getComponent<WidgetComponent>()!;
    _lid.add(screen);
    // Sticker on the back of the lid
    // A disc lies flat facing +y; tip it back to face -z, like the old circle turned round.
    final sticker = mesh(DiscGeometry(radius: 0.07, segments: 20), toon(hex('#ff8a5b')), 0, 0.27, -0.014, false)
      ..rotation = euler(-math.pi / 2, 0);
    _lid.add(sticker);
    _setLid(0); // closed; animates open
  }

  @override
  final Node root = Node(name: 'laptop');
  final Node _lid = Node(name: 'lid');
  late final WidgetComponent _widget;
  final ValueNotifier<_Frame> _frame = ValueNotifier(const _Frame(null, 'booting…', -1));
  int _drawnVersion = -1;
  double _paintedAt = -1e9;
  double _openT = 0;
  double _clock = 0;
  String _placeholder = 'booting…';

  void setPlaceholder(String text) {
    if (text == _placeholder) return;
    _placeholder = text;
    _drawnVersion = -2;
  }

  /// [distance] to the camera throttles repaints: far-away laptops refresh rarely.
  void update(double dt, ScreenState? screen, [double distance = 0]) {
    _clock += dt;
    if (_openT < 1) _setLid(math.min(1, _openT + dt * 1.6));
    final version = screen?.version ?? -1;
    final every = distance < 6 ? 0.15 : distance < 14 ? 0.6 : 2.0;
    if (version != _drawnVersion && (_clock - _paintedAt > every || _drawnVersion < 0)) {
      _paintedAt = _clock;
      _drawnVersion = version;
      _frame.value = _Frame(screen, _placeholder, version);
      // The widget rebuilds this frame; capture once it has painted.
      WidgetsBinding.instance.addPostFrameCallback((_) => _widget.controller.requestCapture());
    }
  }

  /// Folds the lid down a little further (it snaps shut at the end); true once it's closed.
  @override
  bool shut(double dt) {
    _setLid(math.max(0, _openT - dt * 2));
    return _openT == 0;
  }

  void _setLid(double open) {
    _openT = open;
    final e = 1 - math.pow(1 - open, 3);
    _lid.rotation = euler(math.pi / 2 - e * (math.pi / 2 + 0.22), 0);
  }

  @override
  void dispose() => _frame.dispose();
}

class _Frame {
  const _Frame(this.screen, this.placeholder, this.version);
  final ScreenState? screen;
  final String? placeholder;
  final int version;

  // ScreenState changes in place, so compare versions too.
  @override
  bool operator ==(Object other) =>
      other is _Frame && identical(other.screen, screen) && other.placeholder == placeholder && other.version == version;

  @override
  int get hashCode => Object.hash(screen, placeholder, version);
}
