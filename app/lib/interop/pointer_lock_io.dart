// Pointer lock in the desktop app: the macOS runner (MainFlutterWindow.swift, channel
// agent_office/pointer_lock) hides the cursor, pins it to the middle of the window and sends the
// mouse's raw movement here, the way a browser's pointer lock does. The same API as
// pointer_lock_web.dart. Elsewhere (no runner channel, or tests) canLock is false and first person
// looks around by dragging.

import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'mouse_settle.dart';

class PointerLock {
  PointerLock({required this.onMove, this.onChange});

  final void Function(double dx, double dy) onMove;
  final void Function(bool locked)? onChange;

  bool Function() mayLock = () => true;

  /// Holding the view still while the hand that clicked a window shut comes to rest.
  final MouseSettle settle = MouseSettle();

  /// Whether the last thing pressed was a mouse button rather than a key (the page tells it).
  bool get pressedMouse => settle.pressedMouse;

  double _now() => DateTime.now().microsecondsSinceEpoch / 1000;

  static const _channel = MethodChannel('agent_office/pointer_lock');

  bool _locked = false;

  /// False once the runner turns out not to have the channel (an older build, or not macOS).
  bool _available = Platform.isMacOS;

  bool get locked => _locked;
  bool get hasMouse => _locked;
  bool get canLock => _available;
  bool get finePointer => true;

  void _pointer(PointerEvent e) {
    if (e is PointerDownEvent) settle.pressedMouse = true;
  }

  bool _key(KeyEvent e) {
    if (e is KeyDownEvent) settle.pressedMouse = false;
    return false;
  }

  void attach() {
    if (!_available) return;
    // Seen before a window acts on it.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    HardwareKeyboard.instance.addHandler(_key);
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'move':
          final d = call.arguments as List<Object?>;
          if (!settle.looks(_now())) return;
          onMove((d[0]! as num).toDouble(), (d[1]! as num).toDouble());
        case 'changed':
          // The runner lets go by itself when you switch to another app.
          _locked = call.arguments == true;
          if (_locked) settle.landed(_now());
          onChange?.call(_locked);
      }
    });
  }

  void detach() {
    unlock();
    if (!_available) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    HardwareKeyboard.instance.removeHandler(_key);
    _channel.setMethodCallHandler(null);
  }

  /// With [settled] (a click just closed a window), the view holds still until the mouse comes to rest.
  void lock({bool settled = false}) {
    if (!_available || _locked || !mayLock()) return;
    settle.asked(settled);
    _channel.invokeMethod<void>('lock').catchError((Object e) {
      if (e is MissingPluginException) _available = false;
    });
  }

  void unlock() {
    if (!_available || !_locked) return;
    _channel.invokeMethod<void>('unlock').catchError((Object _) {});
  }

  /// In the browser this lets the page take the mouse back after a window; here letting go is enough.
  void yieldMouse() => unlock();
}
