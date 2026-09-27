import 'dart:io';

import 'package:path/path.dart' as p;

/// Flutter's files keep their names from build to build, so browsers must revalidate them.
const cacheRevalidate = 'no-cache';

/// Where the client's files are. AGENT_OFFICE_PUBLIC_DIR overrides it (tests, a custom build).
/// The compiled office looks in the `web` folder next to its binary first. `here` is the folder of
/// the running server's entry point (server/bin under `dart run`), and the checkout's builds are
/// listed relative to it: the Flutter build, then tool/build.dart's dist/agent-office/web.
String findPublicDir(String here, [String? override]) {
  override ??= Platform.environment['AGENT_OFFICE_PUBLIC_DIR'];
  String resolve(String rel) => p.normalize(p.absolute(here, rel));
  final candidates = override != null && override.isNotEmpty
      ? [p.normalize(p.absolute(override))]
      : [
          p.join(p.dirname(Platform.resolvedExecutable), 'web'), // agent-office next to web/ (packaged)
          resolve('../../app/build/web'), // server/bin -> app/build/web (checkout)
          resolve('../../dist/agent-office/web'), // server/bin -> tool/build.dart's output
        ];
  for (final c in candidates) {
    if (File(p.join(c, 'index.html')).existsSync()) return c;
  }
  throw StateError("The client isn't built (looked in ${candidates.join(', ')}). Run `dart run tool/build.dart`.");
}

final _leadingParents = RegExp(r'^(\.\.[/\\])+');

/// A file of the client bundle, or null when it's missing, a folder, or outside the bundle.
String? publicFile(String publicDir, String path) {
  if (path.contains('\u0000')) return null;
  // Joined as text (like Node's path.join), so a leading slash doesn't make it absolute.
  final file = p.normalize('$publicDir${p.separator}${p.normalize(path).replaceFirst(_leadingParents, '')}');
  return file.startsWith(publicDir + p.separator) && FileSystemEntity.typeSync(file) == FileSystemEntityType.file
      ? file
      : null;
}

/// The pages the Flutter router shows to people who aren't signed in yet.
final _flutterPages = RegExp(r'^/(login|join|claim)(\.html)?$');

/// What the Flutter app needs to boot on /login before anyone is signed in. None of it is secret:
/// it's the same for every office.
final _flutterPublic = [
  RegExp(r'^/index\.html$'),
  RegExp(r'^/flutter_bootstrap\.js$'),
  RegExp(r'^/flutter\.js$'),
  RegExp(r'^/flutter_service_worker\.js$'),
  RegExp(r'^/main\.dart(\.[\w-]+)*\.(js|mjs|wasm)$'),
  RegExp(r'^/version\.json$'),
  RegExp(r'^/manifest\.json$'),
  RegExp(r'^/favicon\.[\w]+$'),
  RegExp(r'^/icons/.+'),
  RegExp(r'^/canvaskit/.+'),
  RegExp(r'^/assets/.+'),
];

/// How the office answers a GET of the Flutter client: a file (with its Cache-Control), a redirect,
/// or a 404.
sealed class StaticAnswer {
  const StaticAnswer();
}

class StaticFile extends StaticAnswer {
  const StaticFile(this.file, this.cache);
  final String file;
  final String cache;
  @override
  bool operator ==(Object other) => other is StaticFile && other.file == file && other.cache == cache;
  @override
  int get hashCode => Object.hash(file, cache);
  @override
  String toString() => 'StaticFile($file, $cache)';
}

class StaticRedirect extends StaticAnswer {
  const StaticRedirect(this.location);
  final String location;
  @override
  bool operator ==(Object other) => other is StaticRedirect && other.location == location;
  @override
  int get hashCode => location.hashCode;
  @override
  String toString() => 'StaticRedirect($location)';
}

class StaticNotFound extends StaticAnswer {
  const StaticNotFound();
  @override
  bool operator ==(Object other) => other is StaticNotFound;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'StaticNotFound()';
}

/// How the office answers a GET of the Flutter client, for anything that isn't /api (the caller
/// handles those, and their auth, itself). [path] is the decoded path.
StaticAnswer flutterStatic(String publicDir, String path, bool signedIn) {
  // Matched on the normalised path, so /assets/../secret can't borrow /assets' pass.
  path = p.posix.normalize(path);
  StaticAnswer index() => StaticFile(p.join(publicDir, 'index.html'), cacheRevalidate);
  if (_flutterPages.hasMatch(path)) return index();
  if (_flutterPublic.any((re) => re.hasMatch(path))) {
    final file = publicFile(publicDir, path);
    return file != null ? StaticFile(file, cacheRevalidate) : const StaticNotFound();
  }
  if (!signedIn) return const StaticRedirect('/login');
  if (path == '/') return index();
  if (path == '/api' || path.startsWith('/api/') || path == '/ws') return const StaticNotFound();
  final file = publicFile(publicDir, path);
  if (file != null) return StaticFile(file, cacheRevalidate);
  // A route of the app (no extension): the app reads the path. A missing file is a plain 404.
  if (p.posix.extension(path).isEmpty) return index();
  return const StaticNotFound();
}
