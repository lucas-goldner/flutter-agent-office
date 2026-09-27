// The office page: the 3D floor, the labels over it and the HUD, plus the keyboard, the mouse and
// pointer lock (the old index.html and main.ts's input section). The OfficeController does the work.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' hide Material;

import 'interop/pointer_lock.dart';
import 'office/controller.dart';
import 'office_scope.dart';
import 'ui/hud.dart';
import 'ui/modal.dart';
import 'world/hands.dart';
import 'world/labels.dart';
import 'world/player.dart';

class OfficePage extends StatefulWidget {
  const OfficePage({super.key});

  @override
  State<OfficePage> createState() => _OfficePageState();
}

class _OfficePageState extends State<OfficePage> {
  final OfficeController c = OfficeController();
  final FocusNode _focus = FocusNode(debugLabel: 'office');
  late final PointerLock _lock = PointerLock(
    onMove: (dx, dy) {
      if (c.player.enabled) c.player.look(dx * kLookSpeed, dy * kLookSpeed);
    },
    onChange: (locked) => c.pointerLocked = locked,
  );

  /// Whether the mouse was captured when the windows opened, so closing them gives it back.
  bool _relook = false;
  Offset? _drag;
  double _dragMoved = 0;
  Size _view = Size.zero;

  @override
  void initState() {
    super.initState();
    c.init();
    _lock.attach();
    ModalStack.instance.changes.addListener(_onModals);
    WidgetsBinding.instance.addPostFrameCallback((_) => ModalStack.instance.attach(Overlay.of(context)));
  }

  @override
  void dispose() {
    ModalStack.instance.changes.removeListener(_onModals);
    _lock.detach();
    c.dispose();
    super.dispose();
  }

  void _onModals() {
    final open = ModalStack.instance.open;
    c.player.enabled = !open;
    c.player.input.clear();
    if (open) {
      if (_lock.locked) _relook = true;
      _lock.unlock();
    } else {
      // Once the last window is closed, the game has the keyboard again and, in first person, the mouse.
      Future(() {
        if (ModalStack.instance.open) return;
        _focus.requestFocus();
        if (c.player.view == ViewMode.first && _relook) _lock.lock();
        _relook = false;
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) => c.onKey(e) ? KeyEventResult.handled : KeyEventResult.ignored;

  void _down(PointerDownEvent e) {
    _focus.requestFocus();
    if (!c.player.enabled) return;
    final mouse = e.kind == PointerDeviceKind.mouse;
    if (c.player.view == ViewMode.first && mouse && _lock.canLock) {
      if (_lock.locked) {
        if (e.buttons == kPrimaryMouseButton) c.onClick(Offset(_view.width / 2, _view.height / 2), _view);
        return;
      }
      _lock.lock();
    }
    // Drag to orbit (third person) or to look around (first person without pointer lock).
    _drag = e.localPosition;
    _dragMoved = 0;
  }

  void _move(PointerMoveEvent e) {
    final d = _drag;
    if (d == null || _lock.locked) return;
    final delta = e.localPosition - d;
    _drag = e.localPosition;
    _dragMoved += delta.dx.abs() + delta.dy.abs();
    if (c.player.view == ViewMode.first) {
      c.player.look(delta.dx * kDragLookSpeed, delta.dy * kDragLookSpeed);
    } else {
      c.player.orbit(delta.dx, delta.dy);
    }
  }

  void _up(PointerUpEvent e) {
    final d = _drag;
    _drag = null;
    // A click that captured the mouse is not also a click on the world.
    if (d == null || _dragMoved > 5 || _lock.locked) return;
    final at = c.player.view == ViewMode.first ? Offset(_view.width / 2, _view.height / 2) : e.localPosition;
    c.onClick(at, _view);
  }

  void _wheel(PointerSignalEvent e) {
    if (e is PointerScrollEvent) c.player.zoom(e.scrollDelta.dy);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: c.ready,
    builder: (context, ready, _) => Material(
      type: MaterialType.transparency,
      child: OfficeScope(
        store: c.store,
        net: c.net,
        settings: c.settings,
        actions: c,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<Color>(
                  valueListenable: c.sky,
                  builder: (context, sky, _) => ColoredBox(color: sky),
                ),
              ),
              if (ready) ...[
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      _view = box.biggest;
                      c.lockAvailable = _lock.canLock;
                      return Listener(
                        onPointerDown: _down,
                        onPointerMove: _move,
                        onPointerUp: _up,
                        onPointerSignal: _wheel,
                        child: SceneView(
                          c.scene,
                          onTick: (elapsed, dt) => c.tick(dt, _view),
                          viewsBuilder: (_) => [
                            RenderView(camera: c.camera, layerMask: kRenderLayerAll & ~Hands.layer),
                            if (c.player.view == ViewMode.first && c.devHands) c.hands.overlayView(),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Positioned.fill(
                  child: LabelLayer(hub: c.labels, camera: () => c.camera),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: c.fade,
                      builder: (context, on, _) => AnimatedOpacity(
                        opacity: on ? 1 : 0,
                        duration: const Duration(milliseconds: 300),
                        child: const ColoredBox(color: Color(0xFF14151F)),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Hud(
                    controller: c.hud,
                    voice: c.voice,
                    speaking: c.voiceRoom.speaking,
                    shares: c.voiceRoom.sharesWidget,
                    connected: c.connected,
                    hint: c.hint,
                    crosshair: c.crosshair,
                    hanging: c.hanging,
                    caffeine: c.caffeine,
                    clock: () => c.clockSeconds,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
