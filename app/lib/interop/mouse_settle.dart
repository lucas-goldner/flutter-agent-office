// Taking the mouse back from a click (player.ts lock's `settle`, #191 #198): a window closed with the mouse
// (Send home, ✕, the backdrop) takes it back at once, but the hand that clicked is often still moving on,
// and the rest of that move would swing the view somewhere else. So the view holds still until the mouse has
// rested a moment once it's taken, for the flick of the hand at most. Closing with a key, or clicking the
// office to look around, turns the view straight away. Both pointer locks (web, macOS) use this.

/// How long the mouse must rest once it's taken before it looks around (ms), and how long at most the view
/// is held still for: just the flick of the hand that clicked, or looking around straight away feels like
/// the mouse is gone.
const double settleRest = 100;
const double settleMax = 150;

class MouseSettle {
  /// Whether the last thing pressed was a mouse button rather than a key: a window it closed settles.
  bool pressedMouse = false;

  bool _next = false;
  double _until = 0;
  double _movedAt = 0;

  /// The lock about to be asked for settles (a click just closed a window).
  void asked(bool settle) => _next = settle;

  /// The lock landed at [now] (ms).
  void landed(double now) {
    // The pause to click doesn't count as the hand coming to rest: only once it's taken.
    if (_next) _movedAt = now;
    _until = _next ? _movedAt + settleMax : 0;
    _next = false;
  }

  /// The mouse moved at [now] while locked: whether it may turn the view.
  bool looks(double now) {
    final rested = now - _movedAt;
    _movedAt = now;
    if (_until > 0) {
      if (rested < settleRest && now < _until) return false;
      _until = 0;
    }
    return true;
  }
}
