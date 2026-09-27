// Where the office is, and how to show it who you are. A page the office served talks to it by
// relative URL and the browser keeps the session cookie; the desktop app has no origin of its own,
// so it puts the office's address in front of every path and keeps the cookie itself (per office,
// as the server names it after its port).

import '../interop/browser.dart';

/// [path] (e.g. `/api/whoami`) on the office: as is on the web, absolute in the desktop app.
String serverUrl(String path) => desktopApp && path.startsWith('/') ? '$serverOrigin$path' : path;

Uri serverUri(String path) => Uri.parse(serverUrl(path));

/// What a request to the office carries in the desktop app: the session cookie, and the office's
/// own Origin (it refuses the socket and some posts from any other). Nothing on the web.
Map<String, String> serverHeaders() {
  if (!desktopApp) return const {};
  final cookie = sessionCookie;
  return {'origin': serverOrigin, 'cookie': ?cookie};
}

/// Headers for Image.network: null on the web, so the browser loads it as a plain image.
Map<String, String>? imageHeaders() => desktopApp ? serverHeaders() : null;

String _cookieKey() => 'agent-office.session@$serverOrigin';

/// The office's session cookie (`name=value`) in the desktop app, if you've signed in.
String? get sessionCookie => desktopApp ? storageGet(_cookieKey()) : null;

void forgetSession() => storageRemove(_cookieKey());

final _officeCookie = RegExp(r'^ao_session(?:_\d+)?$');

/// Keeps the session cookie from a response's headers (http's, lower-cased, several Set-Cookie
/// headers joined with commas), or forgets it when the office clears it (signing out).
void takeSessionCookie(Map<String, String> headers) {
  final raw = headers['set-cookie'];
  if (!desktopApp || raw == null) return;
  for (final cookie in raw.split(RegExp(r',(?=\s*[^;,\s=]+=)'))) {
    final attrs = cookie.split(';');
    final pair = attrs.first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0 || !_officeCookie.hasMatch(pair.substring(0, eq))) continue;
    final value = pair.substring(eq + 1);
    final cleared = value.isEmpty || attrs.any((a) => a.trim().toLowerCase() == 'max-age=0');
    if (cleared) {
      forgetSession();
    } else {
      storageSet(_cookieKey(), pair);
    }
  }
}

/// An office's address as typed (`localhost:4600`, `https://office.example.com/login`, an invite
/// link) cut down to its origin, e.g. `http://localhost:4600`; null if it isn't one.
String? normalizeServer(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) s = 'http://$s';
  final Uri u;
  try {
    u = Uri.parse(s);
  } catch (_) {
    return null;
  }
  if ((u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) return null;
  return u.origin;
}
