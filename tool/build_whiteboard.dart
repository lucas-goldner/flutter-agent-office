// Bundles the whiteboard (Excalidraw 0.18, React 18 and app/excalidraw/bridge.js) for the Flutter
// client into app/web/excalidraw/, which `flutter build web` copies to build/web/excalidraw/:
//   whiteboard.js     the bridge, as an ES module the app imports the first time the whiteboard is needed
//   chunk-*.js        what it loads from there (Excalidraw's font subsetting worker, for one)
//   whiteboard.css    Excalidraw's styles, which the bridge adds to the page
//   fonts/            Excalidraw's hand-drawn fonts, served by the office rather than a CDN
// Xiaolai (CJK, 12 MB) is left out: Excalidraw falls back to its CDN for that one, only when someone
// writes Chinese, Japanese or Korean. So are the other languages: the board is in English.
//
// No Node.js or npm: the exact packages (tool/whiteboard.lock.json, from tool/gen_whiteboard_lock.dart)
// are downloaded from registry.npmjs.org, checked against their integrity hashes and unpacked into a
// node_modules/ tree under .dart_tool/whiteboard/, and esbuild's native binary does the bundling.
// Downloads are cached there, so only the first run needs the network.
//
//   dart run tool/build_whiteboard.dart     (from anywhere in the repo; fetches tool/'s Dart packages itself)
//
// The output is gitignored (it's several MB).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Bumped when the way the tree is laid out or patched changes, so old trees are rebuilt.
const _layoutVersion = 1;

final _root = File.fromUri(Platform.script).parent.parent;
String _p(List<String> parts) => parts.join(Platform.pathSeparator);

Future<void> main() async {
  final lockFile = File(_p([_root.path, 'tool', 'whiteboard.lock.json']));
  final lock = jsonDecode(lockFile.readAsStringSync()) as Map<String, dynamic>;
  final work = Directory(_p([_root.path, '.dart_tool', 'whiteboard']));
  final cache = Directory(_p([work.path, 'tarballs']))..createSync(recursive: true);
  final client = _httpClient();
  try {
    final esbuild = await _esbuild(client, lock['esbuild'] as Map<String, dynamic>, work, cache);
    final tree = await _tree(client, lock, work, cache);
    await _bundle(esbuild, tree);
  } finally {
    client.close();
  }
}

/// Honours HTTPS_PROXY and SSL_CERT_FILE (a CA bundle to trust on top of the system's).
HttpClient _httpClient() {
  final context = SecurityContext(withTrustedRoots: true);
  final ca = Platform.environment['SSL_CERT_FILE'];
  if (ca != null && ca.isNotEmpty && File(ca).existsSync()) context.setTrustedCertificates(ca);
  return HttpClient(context: context)..findProxy = HttpClient.findProxyFromEnvironment;
}

/// The tarball at [url], from the cache or the registry, after checking it against [integrity].
Future<Uint8List> _tarball(HttpClient client, Directory cache, String url, String integrity) async {
  final file = File(_p([cache.path, Uri.parse(url).pathSegments.last]));
  final name = Uri.parse(url).path;
  if (file.existsSync()) {
    final bytes = file.readAsBytesSync();
    if (_matches(bytes, integrity)) return bytes;
  }
  for (var attempt = 1;; attempt++) {
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      final builder = BytesBuilder(copy: false);
      await res.forEach(builder.add);
      final bytes = builder.takeBytes();
      if (!_matches(bytes, integrity)) throw StateError('$name does not match its integrity hash');
      final tmp = File('${file.path}.part')..writeAsBytesSync(bytes);
      tmp.renameSync(file.path);
      return bytes;
    } on StateError {
      rethrow;
    } catch (e) {
      if (attempt >= 3) throw StateError('could not download $url: $e');
    }
  }
}

bool _matches(List<int> bytes, String integrity) {
  if (!integrity.startsWith('sha512-')) throw StateError('unsupported integrity $integrity');
  return base64.encode(sha512.convert(bytes).bytes) == integrity.substring('sha512-'.length);
}

/// Unpacks an npm tarball into [dest], dropping its top directory (usually package/).
void _unpack(Uint8List tgz, Directory dest) {
  final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(tgz));
  for (final f in archive.files) {
    if (!f.isFile || f.isSymbolicLink) continue;
    final slash = f.name.indexOf('/');
    if (slash < 0) continue;
    final rel = f.name.substring(slash + 1);
    if (rel.isEmpty || rel.split('/').contains('..')) continue;
    final out = File(_p([dest.path, ...rel.split('/')]));
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(f.content);
  }
}

/// esbuild's native binary for this machine.
Future<String> _esbuild(HttpClient client, Map<String, dynamic> esbuild, Directory work, Directory cache) async {
  final os = Platform.operatingSystem == 'macos' ? 'darwin' : Platform.operatingSystem;
  final v = Platform.version; // "... on "linux_x64""
  final arch = v.contains('_arm64"') ? 'arm64' : (v.contains('_x64"') ? 'x64' : 'unknown');
  final platform = '$os-$arch';
  final entry = (esbuild['platforms'] as Map)[platform] as Map<String, dynamic>? ??
      (throw UnsupportedError('no esbuild binary pinned for $platform (tool/whiteboard.lock.json)'));
  final dir = Directory(_p([work.path, 'esbuild-${esbuild['version']}-$platform']));
  final bin = File(_p([dir.path, 'bin', 'esbuild']));
  if (!bin.existsSync()) {
    final tgz = await _tarball(client, cache, entry['resolved'] as String, entry['integrity'] as String);
    final tmp = Directory('${dir.path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    _unpack(tgz, tmp);
    final chmod = await Process.run('chmod', ['+x', _p([tmp.path, 'bin', 'esbuild'])]);
    if (chmod.exitCode != 0) throw StateError('chmod failed: ${chmod.stderr}');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    tmp.renameSync(dir.path);
  }
  return bin.path;
}

/// The node_modules/ tree the bundle is built from, laid out as npm did (rebuilt when the lock changes).
Future<Directory> _tree(HttpClient client, Map<String, dynamic> lock, Directory work, Directory cache) async {
  final packages = (lock['packages'] as List).cast<Map<String, dynamic>>();
  final stamp = sha256.convert(utf8.encode('$_layoutVersion ${jsonEncode(packages)}')).toString();
  final tree = Directory(_p([work.path, 'tree']));
  final stampFile = File(_p([tree.path, '.stamp']));
  if (stampFile.existsSync() && stampFile.readAsStringSync() == stamp) return tree;

  final tmp = Directory('${tree.path}.tmp');
  if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  tmp.createSync(recursive: true);
  stdout.writeln('build:whiteboard: fetching ${packages.length} packages');
  // A few downloads at a time.
  final pending = [...packages];
  Future<void> worker() async {
    while (pending.isNotEmpty) {
      final pkg = pending.removeLast();
      final tgz = await _tarball(client, cache, pkg['resolved'] as String, pkg['integrity'] as String);
      _unpack(tgz, Directory(_p([tmp.path, ...(pkg['path'] as String).split('/')])));
    }
  }

  await Future.wait([for (var i = 0; i < 8; i++) worker()]);
  _englishOnly(Directory(_p([tmp.path, 'node_modules', '@excalidraw', 'excalidraw', 'dist'])));
  File(_p([tmp.path, '.stamp'])).writeAsStringSync(stamp);
  if (tree.existsSync()) tree.deleteSync(recursive: true);
  tmp.renameSync(tree.path);
  return tree;
}

/// Every language but English becomes an empty module: nothing ever asks for them. (What the npm
/// build's esbuild plugin did; the CLI has no plugins, so the files themselves are emptied.)
void _englishOnly(Directory dist) {
  for (final dir in dist.listSync(recursive: true).whereType<Directory>()) {
    if (dir.uri.pathSegments.where((s) => s.isNotEmpty).last != 'locales') continue;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!RegExp(r'^[\w-]+\.js$').hasMatch(name) || RegExp(r'^(en|percentages)-').hasMatch(name)) continue;
      f.writeAsStringSync('export default {};\n');
    }
  }
}

Future<void> _bundle(String esbuild, Directory tree) async {
  final out = Directory(_p([_root.path, 'app', 'web', 'excalidraw']));
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync(recursive: true);

  // The bridge is bundled from inside the tree, so its bare imports resolve there and nowhere else.
  final src = Directory(_p([tree.path, 'src']))..createSync(recursive: true);
  final entry = File(_p([_root.path, 'app', 'excalidraw', 'bridge.js'])).copySync(_p([src.path, 'bridge.js']));

  final result = await Process.run(esbuild, [
    'whiteboard=${entry.path}',
    '--outdir=${out.path}',
    '--bundle',
    '--splitting',
    '--format=esm',
    '--minify',
    '--target=es2022',
    '--conditions=production',
    '--define:process.env.NODE_ENV="production"',
    '--define:process.env.IS_PREACT="false"',
    // Excalidraw's CSS points at ./fonts/…, which are copied next to it below.
    '--external:*.woff2',
    '--log-level=warning',
    // Excalidraw's Radix UI parts start with "use client", which means nothing outside React Server Components.
    '--log-override:unsupported-directive=silent',
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('build:whiteboard: esbuild failed');
    exit(result.exitCode);
  }

  final fonts = Directory(_p([tree.path, 'node_modules', '@excalidraw', 'excalidraw', 'dist', 'prod', 'fonts']));
  _copy(fonts, Directory(_p([out.path, 'fonts'])));

  var size = 0;
  for (final f in out.listSync(recursive: true).whereType<File>()) {
    size += f.lengthSync();
  }
  stdout.writeln('build:whiteboard: app/web/excalidraw (${(size / 1024 / 1024).toStringAsFixed(1)} MB)');
}

void _copy(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == 'Xiaolai') continue;
    if (e is Directory) {
      _copy(e, Directory(_p([to.path, name])));
    } else if (e is File) {
      e.copySync(_p([to.path, name]));
    }
  }
}
