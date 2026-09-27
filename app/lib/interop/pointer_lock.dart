// Pointer lock for first-person mouse look. Flutter's own pointer events stop moving once the
// pointer is locked, so the raw movementX/Y come straight from the DOM here.

import 'dart:js_interop';

import 'package:web/web.dart' as web;

class PointerLock {
  PointerLock({required this.onMove, this.onChange});

  /// Mouse movement in pixels while locked, clamped against the bogus jump some platforms report.
  final void Function(double dx, double dy) onMove;
  final void Function(bool locked)? onChange;

  bool _failed = false;
  bool _pending = false;
  bool _everLocked = false;
  JSFunction? _move, _change, _error;

  web.Element? get _target => web.document.querySelector('flutter-view') ?? web.document.body;

  bool get locked => web.document.pointerLockElement != null;

  /// Whether clicking the scene will capture the mouse (false once the browser has refused).
  bool get canLock => !_failed;

  void attach() {
    _move = ((web.PointerEvent e) {
      if (!locked) return;
      double clamp(num v) => v.toDouble().clamp(-250, 250);
      onMove(clamp(e.movementX), clamp(e.movementY));
    }).toJS;
    _change = ((web.Event _) {
      _pending = false;
      if (locked) _everLocked = true;
      onChange?.call(locked);
    }).toJS;
    _error = ((web.Event _) {
      _pending = false;
      // Locking right after Esc is refused for a moment; only give up if it never worked.
      if (!_everLocked) _failed = true;
    }).toJS;
    web.document.addEventListener('pointermove', _move);
    web.document.addEventListener('pointerlockchange', _change);
    web.document.addEventListener('pointerlockerror', _error);
  }

  void detach() {
    web.document.removeEventListener('pointermove', _move);
    web.document.removeEventListener('pointerlockchange', _change);
    web.document.removeEventListener('pointerlockerror', _error);
    unlock();
  }

  void lock() {
    if (locked || _pending || _failed) return;
    final el = _target;
    if (el == null) return;
    _pending = true;
    try {
      el.requestPointerLock();
    } catch (_) {
      _pending = false;
      _failed = true;
    }
  }

  void unlock() {
    if (locked) web.document.exitPointerLock();
  }
}
