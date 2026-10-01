// Pointer lock for first-person mouse look: the browser's (pointer_lock_web.dart), and the macOS
// app's through its runner (pointer_lock_io.dart).

export 'pointer_lock_io.dart' if (dart.library.js_interop) 'pointer_lock_web.dart';
