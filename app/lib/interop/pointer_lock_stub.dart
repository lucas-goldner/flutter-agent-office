// No pointer lock in the desktop app yet (stage 2: hide and re-centre the cursor through a small
// platform channel). canLock is false, so first person looks around by dragging, as a browser that
// refuses the lock does. The same API as pointer_lock_web.dart.

class PointerLock {
  PointerLock({required this.onMove, this.onChange});

  final void Function(double dx, double dy) onMove;
  final void Function(bool locked)? onChange;

  bool Function() mayLock = () => true;

  bool get locked => false;
  bool get hasMouse => false;
  bool get canLock => false;
  bool get finePointer => true;

  void attach() {}
  void detach() {}
  void lock() {}
  void unlock() {}
  void yieldMouse() {}
}
