// The office page: the 3D floor, the labels over it and the HUD, plus the keyboard, the mouse and
// pointer lock (the old index.html and main.ts's input section). The OfficeController does the work.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' hide Material;

import 'interop/pointer_lock.dart';
import 'office/controller.dart';
import 'office_scope.dart';
import 'ui/arcade.dart';
import 'ui/compass.dart';
import 'ui/emote_wheel.dart';
import 'ui/shot_meter.dart';
import 'ui/hud.dart';
import 'ui/modal.dart';
import 'world/drunk.dart';
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
      // While the emote wheel is open, the mouse points at an emote instead of looking around.
      if (c.emoteWheel.isOpen) return c.emoteWheel.move(dx, dy);
      if (c.player.enabled) c.player.look(dx * kLookSpeed, dy * kLookSpeed);
    },
    onChange: (locked) {
      c.pointerLocked = locked;
      if (locked) c.relookOnKey = false;
      // A lock that lands with a window open (the one yieldMouse takes, or a relock racing the next
      // window) lets go: the whiteboard's Excalidraw, a terminal's text need the real mouse.
      if (locked && ModalStack.instance.open) _lock.unlock();
    },
  );

  Offset? _drag;
  double _dragMoved = 0;
  Size _view = Size.zero;

  @override
  void initState() {
    super.initState();
    c.init();
    _lock
      ..mayLock = (() => !ModalStack.instance.open && c.player.view == ViewMode.first)
      ..attach();
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
      c.emoteWheel.close();
      // A phone has no mouse to take back afterwards.
      _lock.finePointer ? _lock.yieldMouse() : _lock.unlock();
    } else {
      // A tick later, so closing one window to open the next (Settings → character) doesn't grab
      // the mouse in between.
      Future(_backToGame);
    }
  }

  /// Once the last window is closed, the game has the keyboard again and, in first person, the mouse.
  void _backToGame() {
    if (ModalStack.instance.open) return;
    _focus.requestFocus();
    if (c.player.view != ViewMode.first || !_lock.canLock || _lock.hasMouse) return;
    // The browser lets a page re-capture the mouse it let go of itself (see yieldMouse), even on Esc,
    // and any time after a click, like one on ✕. When it won't, the next key you press does.
    _lock.lock();
    c.relookOnKey = true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (c.relookOnKey &&
        e is KeyDownEvent &&
        e.logicalKey != LogicalKeyboardKey.escape &&
        !ModalStack.instance.open &&
        !c.hud.typing &&
        _lock.canLock) {
      _lock.lock();
    }
    if (c.onKey(e)) return KeyEventResult.handled;
    // In the desktop app a key nobody takes goes on to macOS, which beeps for it: every press and
    // repeat of W/A/S/D (read from the keys held, not here) went "dop dop dop". While you walk
    // around, the game has the keyboard and keeps them; windows and the chat keep their own keys (Tab
    // between fields), and ⌘/Ctrl shortcuts still reach the system. The browser gets them back as
    // before (it doesn't beep, and has its own keys to keep).
    if (!kIsWeb && !ModalStack.instance.open && !c.hud.typing && !_systemShortcut()) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  bool _systemShortcut() {
    final hk = HardwareKeyboard.instance;
    return hk.isMetaPressed || hk.isControlPressed;
  }

  /// The trackpad's two-finger swipe turns the camera the way dragging does, and a pinch zooms the
  /// third-person camera (macOS sends these as pan/zoom gestures, not as a scroll wheel).
  double _pinch = 1;

  void _panZoomStart(PointerPanZoomStartEvent e) => _pinch = 1;

  void _panZoom(PointerPanZoomUpdateEvent e) {
    if (!c.player.enabled || c.hanger.active) return;
    final d = e.panDelta;
    if (c.player.view == ViewMode.first) {
      c.player.look(d.dx * kDragLookSpeed, d.dy * kDragLookSpeed);
    } else {
      c.player.orbit(d.dx, d.dy);
    }
    if (e.scale != _pinch) {
      // Fingers apart (scale up) brings the camera in.
      c.player.zoom((_pinch - e.scale) * 400);
      _pinch = e.scale;
    }
  }

  void _down(PointerDownEvent e) {
    _focus.requestFocus();
    if (!c.player.enabled) return;
    final mouse = e.kind == PointerDeviceKind.mouse;
    if (c.player.view == ViewMode.first && mouse && _lock.canLock) {
      if (_lock.locked) {
        // No cursor while it's captured: a click picks what the emote wheel points at.
        if (c.emoteWheel.isOpen) return c.emoteWheel.click();
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
    c.hanger.mouse = e.localPosition;
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
    if (e is! PointerScrollEvent) return;
    // Hanging a picture, the wheel sizes it instead of zooming the camera.
    c.hanger.active ? c.hanger.resize(e.scrollDelta.dy < 0 ? 1 : -1) : c.player.zoom(e.scrollDelta.dy);
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
                        onPointerPanZoomStart: _panZoomStart,
                        onPointerPanZoomUpdate: _panZoom,
                        onPointerHover: (e) => c.hanger.mouse = e.localPosition,
                        // A few drinks in at the rooftop bar, the frame sways, blurs and warms (world/drunk.dart).
                        child: DrunkVision(
                          look: c.roofHub.look,
                          child: FrameSkipSceneView(
                            c.scene,
                            every: () => 1,
                            onTick: (elapsed, dt) => c.tick(dt, _view),
                            viewsBuilder: (_) => [
                              RenderView(camera: c.camera, layerMask: kRenderLayerAll & ~Hands.layer),
                              if (c.player.view == ViewMode.first && c.devHands && !c.arcade.zoomed && !c.rooms.zoomed)
                                c.hands.overlayView(),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Positioned.fill(
                  child: LabelLayer(hub: c.labels, camera: () => c.camera, blocked: c.labelBlocked),
                ),
                Positioned.fill(
                  child: CompassLayer(
                    camera: () => c.camera,
                    bearings: c.waitingBearings,
                    waiting: c.waitingChip,
                    onNext: c.goToNextWaiting,
                    // The dock on the top bar has it (the ☰ HUD's 'waiting' action).
                    chip: false,
                  ),
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
                Positioned(
                  left: 0,
                  right: 0,
                  top: 70,
                  child: ValueListenableBuilder(
                    valueListenable: c.rooms.golfPanel,
                    builder: (context, g, _) => g == null ? const SizedBox.shrink() : Center(child: GolfPanelView(g)),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 120,
                  child: ValueListenableBuilder(
                    valueListenable: c.rooms.meter,
                    builder: (context, m, _) => m == null
                        ? const SizedBox.shrink()
                        : Center(
                            child: ShotMeterBar(at: m.at, sweet: m.aimed),
                          ),
                  ),
                ),
                // A floor blown up under you: the white-hot flash.
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: c.flash,
                      builder: (context, v, _) => v <= 0
                          ? const SizedBox.shrink()
                          : ColoredBox(color: const Color(0xFFFFF4D6).withValues(alpha: v * 0.9)),
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
                Positioned.fill(child: EmotePop(pop: c.emotePop)),
                Positioned.fill(child: EmoteWheelView(wheel: c.emoteWheel)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
