// The office's sound: Web Audio in the browser (sound_web.dart). The desktop app is silent for now
// (sound_stub.dart), with the same OfficeSound for the office to call.

export 'sound_stub.dart' if (dart.library.js_interop) 'sound_web.dart';
