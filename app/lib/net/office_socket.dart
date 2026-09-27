// The office's WebSocket: the browser's on the web, dart:io's in the desktop app (which has to
// bring the session cookie and the office's Origin itself). Both have the same OfficeSocket.

export 'office_socket_io.dart' if (dart.library.js_interop) 'office_socket_web.dart';
