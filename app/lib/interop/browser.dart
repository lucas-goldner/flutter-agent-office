// Small wrappers over the browser, so the rest of the app doesn't reach for package:web directly:
// the real ones on the web (browser_web.dart), and in the desktop app (and widget tests) stand-ins
// for them (browser_io.dart): an in-app route, the office's address as a setting, a JSON file for
// localStorage.

import 'package:flutter/foundation.dart' show kIsWeb;

export 'browser_io.dart' if (dart.library.js_interop) 'browser_web.dart';

/// Running as the desktop app (macOS) rather than as the page the office serves.
const bool desktopApp = !kIsWeb;

/// What to say where the desktop app can't do something the browser can (yet).
String notInDesktopApp(String what) =>
    '$what isn’t available in the desktop app yet — open the office in a browser for it';
