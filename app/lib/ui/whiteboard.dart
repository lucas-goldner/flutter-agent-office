// The 📝 whiteboard: Excalidraw in the browser (whiteboard_web.dart). The desktop app has no web
// view to run it in yet (whiteboard_stub.dart), so there the window says so and the board in the
// office stays blank.

export 'whiteboard_stub.dart' if (dart.library.js_interop) 'whiteboard_web.dart';
