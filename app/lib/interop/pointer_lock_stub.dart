// No pointer lock in the desktop app yet (stage 2: hide and re-centre the cursor through a small
// platform channel). canLock is false, so first person looks around by dragging, as a browser that
// refuses the lock does.

class PointerLock {
  PointerLock({required this.onMove, this.onChange});

  final void Function(double dx, double dy) onMove;
  final void Function(bool locked)? onChange;

  bool get locked => false;
  bool get canLock => false;

  void attach() {}
  void detach() {}
  void lock() {}
  void unlock() {}
}
