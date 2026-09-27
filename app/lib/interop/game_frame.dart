// The page DEADFALL plays in (ui/arcade.dart): an <iframe> on the web, a dark box on the Dart VM.

export 'game_frame_stub.dart' if (dart.library.js_interop) 'game_frame_web.dart';
