// A web page shown in a window (a terminal's pinned tab): an iframe on the web, a WKWebView in the
// desktop app.

export 'web_page_native.dart' if (dart.library.js_interop) 'web_page_web.dart';
