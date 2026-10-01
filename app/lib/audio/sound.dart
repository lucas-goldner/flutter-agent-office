// The office's sound: Web Audio in the browser (sound_web.dart); in the desktop app the same sounds,
// rendered by the offline synth and played through SoLoud (sound_native.dart). Both have the same
// OfficeSound for the office to call.

export 'sound_native.dart' if (dart.library.js_interop) 'sound_web.dart';
