// The browser's speech recognizer (the Web Speech API), for dictation (ui/dictate.dart). Chrome, Edge
// and Safari have one; Firefox and the desktop app don't, and then there's no 🎤.

import '../ui/speech_logic.dart';
import 'speech_stub.dart' if (dart.library.js_interop) 'speech_web.dart' as impl;

enum SpeechSupport {
  ok,

  /// A page over plain http, where no browser hands out the mic.
  insecure,
  none,
}

/// The browser's recognizer, if it has one.
RecognizerFactory? recognizer() => impl.recognizer();

/// Whether this browser can take dictation.
SpeechSupport speechSupport() {
  if (recognizer() == null) return SpeechSupport.none;
  return impl.secureContext() ? SpeechSupport.ok : SpeechSupport.insecure;
}

/// The language to listen for: the browser's.
String speechLang() => impl.language();

/// Chrome on Android, which listens a phrase at a time.
bool speechOnPhone() => impl.android();

/// Asks whether [lang] can be recognized on the device; null where the browser can't say.
Future<bool> Function(String lang)? speechOnDevice() => impl.onDevice();
