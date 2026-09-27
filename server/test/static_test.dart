import 'dart:io';

import 'package:agent_office_server/src/static.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // A stand-in for app/build/web, with a secret next to it that must never be served.
  late String root;
  late String web;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('ao-flutter-').resolveSymbolicLinksSync();
    web = p.join(root, 'web');
    for (final f in [
      'index.html',
      'flutter_bootstrap.js',
      'flutter.js',
      'main.dart.js',
      'main.dart.mjs',
      'main.dart.wasm',
      'main.dart.js_1.part.js',
      'flutter_service_worker.js',
      'version.json',
      'manifest.json',
      'favicon.svg',
      'icons/Icon-192.png',
      'canvaskit/canvaskit.js',
      'canvaskit/canvaskit.wasm',
      'canvaskit/chromium/canvaskit.wasm',
      'assets/AssetManifest.bin',
      'assets/fonts/MaterialIcons-Regular.otf',
      'assets/shaders/ink_sparkle.frag',
      'extra.txt',
    ]) {
      Directory(p.dirname(p.join(web, f))).createSync(recursive: true);
      File(p.join(web, f)).writeAsStringSync(f);
    }
    File(p.join(root, 'secret.txt')).writeAsStringSync('nope');
  });
  tearDownAll(() => Directory(root).deleteSync(recursive: true));

  StaticAnswer out(String path, [bool signedIn = false]) => flutterStatic(web, path, signedIn);
  String served(String path, [bool signedIn = false]) {
    final a = out(path, signedIn);
    expect(a, isA<StaticFile>(), reason: '$path should be served, got $a');
    return p.relative((a as StaticFile).file, from: web);
  }

  test('signed out: /login, /join and /claim boot the app', () {
    for (final path in ['/login', '/login.html', '/join', '/join.html', '/claim', '/claim.html']) {
      expect(served(path), 'index.html');
    }
  });

  test('signed out: the files the app boots from are served, and revalidated', () {
    for (final path in [
      '/index.html',
      '/flutter_bootstrap.js',
      '/flutter.js',
      '/main.dart.js',
      '/main.dart.mjs',
      '/main.dart.wasm',
      '/main.dart.js_1.part.js',
      '/flutter_service_worker.js',
      '/version.json',
      '/manifest.json',
      '/favicon.svg',
      '/icons/Icon-192.png',
      '/canvaskit/canvaskit.wasm',
      '/canvaskit/chromium/canvaskit.wasm',
      '/assets/AssetManifest.bin',
      '/assets/fonts/MaterialIcons-Regular.otf',
      '/assets/shaders/ink_sparkle.frag',
    ]) {
      expect(served(path), path.substring(1));
      final a = out(path);
      expect(a is StaticFile ? a.cache : null, cacheRevalidate);
    }
  });

  test('signed out: a missing boot file is a 404, not the login redirect', () {
    expect(out('/canvaskit/skwasm.wasm'), const StaticNotFound());
    expect(out('/assets/nope.png'), const StaticNotFound());
  });

  test('signed out: / and everything else goes to /login', () {
    for (final path in ['/', '/office', '/extra.txt', '/api', '/ws']) {
      expect(out(path), const StaticRedirect('/login'));
    }
  });

  test('path traversal never leaves the bundle, nor borrows a public prefix', () {
    for (final signedIn in [false, true]) {
      for (final path in [
        '/../secret.txt',
        '/assets/../../secret.txt',
        '/canvaskit/../../../secret.txt',
        '/../../../../etc/passwd',
        '/assets/..%2f..%2fsecret.txt',
      ]) {
        final a = out(path, signedIn);
        expect(a is! StaticFile || a.file.startsWith(web + p.separator), isTrue, reason: '$path escaped: $a');
        expect(a is! StaticFile || !a.file.endsWith('secret.txt'), isTrue);
      }
    }
    // /assets/../extra.txt is /extra.txt, which needs a session.
    expect(out('/assets/../extra.txt'), const StaticRedirect('/login'));
    expect(publicFile(web, '/../secret.txt'), isNull);
    expect(publicFile(web, '/index.html\u0000.png'), isNull);
    expect(publicFile(web, '/canvaskit'), isNull, reason: 'a folder is not a file');
  });

  test('signed in: files, then the SPA fallback for routes, 404 for missing files', () {
    expect(served('/', true), 'index.html');
    expect(served('/extra.txt', true), 'extra.txt');
    expect(served('/login', true), 'index.html');
    expect(served('/office', true), 'index.html');
    expect(served('/floors/acme/repo', true), 'index.html');
    expect(out('/missing.js', true), const StaticNotFound());
    expect(out('/api', true), const StaticNotFound());
    expect(out('/ws', true), const StaticNotFound());
  });

  test('findPublicDir: the override wins, and a missing bundle says how to build it', () {
    expect(findPublicDir('/nowhere', web), web);
    expect(
      () => findPublicDir('/nowhere', p.join(root, 'none')),
      throwsA(predicate((e) => e.toString().contains('dart run tool/build.dart'))),
    );
    // Under `dart run` the entry point is server/bin, and the checkout's Flutter build is found.
    final build = p.join(root, 'app', 'build', 'web');
    Directory(build).createSync(recursive: true);
    File(p.join(build, 'index.html')).writeAsStringSync('');
    expect(findPublicDir(p.join(root, 'server', 'bin'), ''), build);
  });

  test('findPublicDir: a web folder next to the binary comes first', () {
    final exeWeb = p.join(p.dirname(Platform.resolvedExecutable), 'web');
    // Only checkable when nothing is there already; the candidate list is what matters.
    if (File(p.join(exeWeb, 'index.html')).existsSync()) return;
    expect(
      () => findPublicDir('/nowhere', ''),
      throwsA(predicate((e) => e.toString().contains('looked in $exeWeb, '))),
    );
  });
}
