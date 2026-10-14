// Small wrappers over the browser, so the rest of the app doesn't reach for package:web directly:
// the real ones on the web (browser_web.dart), and in the desktop app (and widget tests) stand-ins
// for them (browser_io.dart): an in-app route, the office's address as a setting, a JSON file for
// localStorage.

import 'package:flutter/foundation.dart' show kIsWeb;

import 'browser_io.dart' if (dart.library.js_interop) 'browser_web.dart' show pagePath;

export 'browser_io.dart' if (dart.library.js_interop) 'browser_web.dart';

/// Running as the desktop app (macOS) rather than as the page the office serves.
const bool desktopApp = !kIsWeb;

/// What to say where the desktop app can't do something the browser can (yet).
String notInDesktopApp(String what) =>
    '$what isn’t available in the desktop app yet — open the office in a browser for it';

/// The sign-in page, coming back to the 2D view afterwards if that's where you are (see [loginNext]).
String loginUrl([String? path]) => (path ?? pagePath) == '/lite' ? '/login?next=/lite' : '/login';

/// Where to go once signed in: the 2D view if that's where you were headed (?next=/lite), else the office.
String loginNext(Map<String, String> query) => query['next'] == '/lite' ? '/lite' : '/';
