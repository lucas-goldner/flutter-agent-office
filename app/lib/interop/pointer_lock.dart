// Pointer lock for first-person mouse look: the browser's (pointer_lock_web.dart), and none yet in
// the desktop app (pointer_lock_stub.dart), where dragging looks around instead.

export 'pointer_lock_stub.dart' if (dart.library.js_interop) 'pointer_lock_web.dart';
