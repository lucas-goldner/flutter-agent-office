import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/changes.dart';
import 'package:agent_office_server/src/decor.dart' show ImageData, ImageError, ImageResult;
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A git repo with one committed picture, and a Changes that diffs it against HEAD.
({String root, String dir, Changes changes}) fixture() {
  final root = Directory.systemTemp.createTempSync('office-changes-').path;
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  final dir = p.join(root, 'repo');
  Directory(p.join(dir, 'assets')).createSync(recursive: true);
  void git(List<String> args) {
    final r = Process.runSync('git', args, workingDirectory: dir);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  git(['init', '-q', '-b', 'main']);
  File(p.join(dir, 'assets', 'logo.png')).writeAsStringSync('old picture');
  File(p.join(dir, 'assets', 'gone.gif')).writeAsStringSync('deleted picture');
  File(p.join(dir, 'README.md')).writeAsStringSync('# demo\n');
  git(['add', '.']);
  git(['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init']);
  final target = ChangesTarget(name: 'Worker 1', cwd: dir, rel: '');
  final changes = Changes(
    dir,
    'main',
    (id) => id == 'w1' ? target : null,
    (_) => null,
    ChangesEvents(state: (_, _) {}, toast: (_, _) {}, refreshGitHub: () {}),
  );
  addTearDown(changes.stop);
  return (root: root, dir: dir, changes: changes);
}

Object text(ImageResult r) => switch (r) {
  ImageData(:final type, :final body) => {'type': type, 'body': utf8.decode(body)},
  ImageError(:final status) => status,
};

void main() {
  test('only pictures have a preview type, picked by extension', () {
    expect(changedImageType('assets/showcase/hero.webp'), 'image/webp');
    expect(changedImageType('a/b/PHOTO.JPG'), 'image/jpeg');
    expect(changedImageType('x.jpeg'), 'image/jpeg');
    expect(changedImageType('icon.svg'), 'image/svg+xml');
    expect(changedImageType('favicon.ico'), 'image/x-icon');
    for (final f in ['README.md', 'archive.zip', 'png', '.png', 'dir.png/file', 'x.constructor', 'x.__proto__', 'x.']) {
      expect(changedImageType(f), isNull, reason: f);
    }
  });

  test('a file outside the checkout, by .. or by a link, is refused', () async {
    final (:root, :dir, :changes) = fixture();
    final outside = p.join(root, 'outside');
    Directory(outside).createSync();
    File(p.join(outside, 'secret.png')).writeAsStringSync('secret');
    expect(
      await insideCheckout(dir, 'assets/logo.png'),
      File(p.join(dir, 'assets', 'logo.png')).resolveSymbolicLinksSync(),
    );
    expect(await insideCheckout(dir, '../outside/secret.png'), isNull);
    expect(await insideCheckout(dir, p.join(outside, 'secret.png')), isNull);
    expect(await insideCheckout(dir, 'missing.png'), isNull);
    Link(p.join(dir, 'link')).createSync(outside);
    expect(await insideCheckout(dir, 'link/secret.png'), isNull);
    // Even when the link itself is one of the worker's changes.
    expect(text(await changes.file('w1', 'link/secret.png', old: false)), 404);
  });

  test('the preview serves both sides of a changed picture, and nothing outside the list of changes', () async {
    final (:root, :dir, :changes) = fixture();
    File(p.join(dir, 'assets', 'logo.png')).writeAsStringSync('new picture');
    File(p.join(dir, 'assets', 'hero.webp')).writeAsStringSync('added picture');
    File(p.join(dir, 'notes.txt')).writeAsStringSync('not a picture');
    File(p.join(dir, 'assets', 'gone.gif')).deleteSync();

    Future<Object> side(bool old, String f) async => text(await changes.file('w1', f, old: old));
    expect(await side(true, 'assets/logo.png'), {'type': 'image/png', 'body': 'old picture'});
    expect(await side(false, 'assets/logo.png'), {'type': 'image/png', 'body': 'new picture'});
    expect(await side(false, 'assets/hero.webp'), {'type': 'image/webp', 'body': 'added picture'});
    expect(await side(true, 'assets/hero.webp'), 404);
    expect(await side(true, 'assets/gone.gif'), {'type': 'image/gif', 'body': 'deleted picture'});
    expect(await side(false, 'assets/gone.gif'), 404);

    // Not a picture, not changed, not in the checkout, no such worker.
    expect(await side(false, 'notes.txt'), 415);
    File(p.join(root, 'secret.png')).writeAsStringSync('secret');
    for (final f in ['README.png', '../secret.png', p.join(root, 'secret.png')]) {
      expect(await side(false, f), 404, reason: f);
    }
    expect(text(await changes.file('nobody', 'assets/logo.png', old: false)), 404);
  });

  test('a renamed picture shows its old name before and its new name after', () async {
    final (:root, :dir, :changes) = fixture();
    Process.runSync('git', ['mv', 'assets/logo.png', 'assets/brand.png'], workingDirectory: dir);
    expect(text(await changes.file('w1', 'assets/brand.png', old: true)), {'type': 'image/png', 'body': 'old picture'});
    expect(text(await changes.file('w1', 'assets/brand.png', old: false)), {
      'type': 'image/png',
      'body': 'old picture',
    });
  });
}
