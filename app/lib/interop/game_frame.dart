// The page DEADFALL plays in (ui/arcade.dart): an <iframe> on the web, a dark box on the Dart VM
// (the desktop app doesn't have a web view yet, so the arcade says so instead of opening).

export 'game_frame_stub.dart' if (dart.library.js_interop) 'game_frame_web.dart';
