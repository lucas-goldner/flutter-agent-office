// Pointer lock for first-person mouse look. Flutter's own pointer events stop moving once the
// pointer is locked, so the raw movementX/Y come straight from the DOM here.
//
// Getting the mouse back after a window closes is the fiddly part (player.ts, #112 #115 fff492d):
// the browser only hands it back without a click or key to a page that let go of it itself, the Esc
// that closes a window isn't a click or key, and Chrome lets go of the mouse on Esc coming up as
// well as going down.

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

  /// Whether a click or key was behind the lock last asked for. Without one, a refusal is just the browser's rule.
  bool _lockOnGesture = false;

  /// The page is letting go of the mouse itself, which isn't you pressing Esc or another tab taking it.
  bool _letting = false;

  /// Whether the page was the one to let go of the mouse last. Only then does the browser hand it
  /// back without a click or key behind the asking.
  bool _letGo = false;

  /// Asked for while the page was still letting go of it: taken back as soon as it's free.
  bool _lockAfter = false;

  /// When Esc last went down and hasn't come up yet (0 once it has).
  double _escDownAt = 0;

  /// Asked for while Esc was down: taken once it comes up.
  bool _lockOnEscUp = false;

  /// Whether a lock may be taken right now (no window open, first person): the page says.
  bool Function() mayLock = () => true;

  JSFunction? _move, _change, _error, _escDown, _escUp, _blur;

  web.Element? get _target => web.document.querySelector('flutter-view') ?? web.document.body;

  bool get locked => web.document.pointerLockElement != null;

  /// Whether the mouse is captured and staying so: not while it's being let go of for a window.
  bool get hasMouse => locked && !_letting;

  /// Whether clicking the scene will capture the mouse (false once the browser has refused).
  bool get canLock => !_failed;

  /// A mouse (not a finger): only then is there a mouse to take back after a window.
  bool get finePointer => web.window.matchMedia('(pointer: fine)').matches;

  bool get _userActive {
    try {
      return web.window.navigator.userActivation.isActive;
    } catch (_) {
      return true;
    }
  }

  void attach() {
    _move = ((web.PointerEvent e) {
      if (!locked) return;
      double clamp(num v) => v.toDouble().clamp(-250, 250);
      onMove(clamp(e.movementX), clamp(e.movementY));
    }).toJS;
    _change = ((web.Event _) {
      _pending = false;
      if (!locked) {
        _letGo = _letting;
        _letting = false;
        final again = _lockAfter && mayLock();
        _lockAfter = false;
        if (again) lock();
      } else {
        _everLocked = true;
      }
      onChange?.call(locked);
    }).toJS;
    _error = ((web.Event _) => _refused()).toJS;
    // Captured, since the window an Esc closes stops it going any further.
    _escDown = ((web.KeyboardEvent e) {
      if (e.key == 'Escape') _escDownAt = web.window.performance.now();
    }).toJS;
    _escUp = ((web.KeyboardEvent e) {
      if (e.key != 'Escape') return;
      _escDownAt = 0;
      final again = _lockOnEscUp && mayLock();
      _lockOnEscUp = false;
      if (!again) return;
      // Taken here, the browser doesn't also treat this Esc as its own shortcut once the page is
      // done with it, which would let go of the mouse just taken.
      e.preventDefault();
      lock();
    }).toJS;
    _blur = ((web.Event _) {
      _escDownAt = 0;
      _lockOnEscUp = false;
    }).toJS;
    web.document.addEventListener('pointermove', _move);
    web.document.addEventListener('pointerlockchange', _change);
    web.document.addEventListener('pointerlockerror', _error);
    web.window.addEventListener('keydown', _escDown, true.toJS);
    web.window.addEventListener('keyup', _escUp, true.toJS);
    web.window.addEventListener('blur', _blur);
  }

  void detach() {
    web.document.removeEventListener('pointermove', _move);
    web.document.removeEventListener('pointerlockchange', _change);
    web.document.removeEventListener('pointerlockerror', _error);
    web.window.removeEventListener('keydown', _escDown, true.toJS);
    web.window.removeEventListener('keyup', _escUp, true.toJS);
    web.window.removeEventListener('blur', _blur);
    unlock();
  }

  /// Captures the mouse for looking around, as the first click on the scene does.
  void lock() {
    // Still being let go of, for a window that closed again at once: taken back once it's free.
    if (locked && _letting) _lockAfter = true;
    if (locked || _pending || _failed) return;
    // The browser lets go of the mouse on Esc coming up as well as going down, so a lock taken
    // between the two (the Esc that closed a window) is gone again at once. Asked for once Esc is
    // up instead. A second on, Esc being held would have repeated, so its keyup went missing.
    if (_escDownAt > 0 && web.window.performance.now() - _escDownAt < 1000) {
      _lockOnEscUp = true;
      return;
    }
    _lockOnEscUp = false;
    final el = _target;
    if (el == null) return;
    _pending = true;
    _lockOnGesture = _userActive;
    // Asking uses up the browser's leave to hand the mouse back, whatever it answers.
    _letGo = false;
    try {
      el.requestPointerLock();
    } catch (_) {
      _pending = false;
      _failed = true;
    }
  }

  void _refused() {
    _pending = false;
    // Locking right after Esc is refused for a moment, and so is asking with no click or key behind
    // it; only give up if it never worked when a click or key asked.
    if (!_everLocked && _lockOnGesture) _failed = true;
  }

  void unlock() {
    _lockAfter = false;
    _lockOnEscUp = false;
    if (!locked) return;
    _letting = true;
    web.document.exitPointerLock();
  }

  /// Frees the mouse for a window over the game, so that [lock] gets it back when the window closes.
  /// The browser only hands the mouse back without a click or key to a page that let go of it
  /// itself. So when the mouse is free already, the click or key that opens the window takes it for
  /// a moment, and it's let go as soon as it lands (see the page's onChange).
  void yieldMouse() {
    if (locked) return unlock();
    if (_letGo || _failed || !_userActive) return;
    lock();
  }
}
