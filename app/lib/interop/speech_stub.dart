// No speech recognition off the web: the desktop app has no 🎤.

import '../ui/speech_logic.dart';

RecognizerFactory? recognizer() => null;
bool secureContext() => false;
String language() => 'en-US';
bool android() => false;
Future<bool> Function(String lang)? onDevice() => null;
