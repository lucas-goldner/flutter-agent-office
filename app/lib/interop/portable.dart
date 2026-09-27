// The few browser calls the windows make, behind a conditional export so the files that use them
// still load on the Dart VM (widget tests), where they fall back to an in-memory stand-in.

export 'portable_stub.dart' if (dart.library.js_interop) 'portable_web.dart';
