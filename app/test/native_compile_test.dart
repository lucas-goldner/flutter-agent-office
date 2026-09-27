// The desktop app's build: flutter test runs on the Dart VM, as the macOS app does, so this only
// compiles if nothing web-only (dart:js_interop, package:web) is reachable from the app's entry
// point. It also checks the stand-ins that make it work there.

import 'package:flutter_test/flutter_test.dart';

import 'package:agent_office/interop/browser.dart';
import 'package:agent_office/main.dart' as app;
import 'package:agent_office/net/server.dart';

void main() {
  test('the whole app compiles for a native target', () {
    expect(app.main, isA<Function>());
    expect(const app.AgentOfficeApp(), isNotNull);
    expect(desktopApp, isTrue);
  });

  test('paths go to the office, with its Origin and the session cookie', () {
    expect(serverOrigin, defaultServerOrigin);
    expect(serverUrl('/api/whoami'), 'http://localhost:4600/api/whoami');
    expect(serverUrl('https://example.com/x.png'), 'https://example.com/x.png');
    expect(serverHeaders(), {'origin': 'http://localhost:4600'});
    takeSessionCookie({'set-cookie': 'ao_session_4600=abc.def; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000'});
    expect(sessionCookie, 'ao_session_4600=abc.def');
    expect(serverHeaders()['cookie'], 'ao_session_4600=abc.def');
    // Someone else's cookie is left alone; signing out clears ours.
    takeSessionCookie({'set-cookie': 'other=1; Path=/'});
    expect(sessionCookie, 'ao_session_4600=abc.def');
    takeSessionCookie({'set-cookie': 'ao_session_4600=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0'});
    expect(sessionCookie, isNull);
  });

  test('an office address is cut down to its origin', () {
    expect(normalizeServer('localhost:4600'), 'http://localhost:4600');
    expect(normalizeServer(' https://office.example.com/join#tok '), 'https://office.example.com');
    expect(normalizeServer('http://[::1]:4600/'), 'http://[::1]:4600');
    expect(normalizeServer('ftp://x'), isNull);
    expect(normalizeServer(''), isNull);
  });

  test('the in-app route stands in for the address bar', () {
    var changes = 0;
    void count() => changes++;
    navigation!.addListener(count);
    expect(locationPath, '/login');
    goTo('/join#token123');
    expect(locationPath, '/join');
    expect(locationHash, '#token123');
    goTo('/claim?t=abc');
    expect(locationSearch, '?t=abc');
    replaceUrl('/claim');
    expect(locationSearch, '');
    final key = pageKey;
    reloadPage();
    expect(pageKey, isNot(key));
    expect(changes, 3);
    navigation!.removeListener(count);
  });
}
