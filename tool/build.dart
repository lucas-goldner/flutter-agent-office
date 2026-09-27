// Builds the office into dist/agent-office/, the folder a release ships:
//   agent-office      the one executable (server, CLI, PTY host), from server/bin/agent_office.dart
//   web/              the Flutter web client (app/build/web without the engine's debug symbols)
//   install.json      what this build is: its repo, tag, platform and commit (read by the upgrader)
//
//   dart run tool/build.dart [--pack] [--version 0.1.68] [--repo owner/name] [--skip-web-build]
//
// --pack also writes dist/agent-office-<os>-<arch>.tar.gz and its line of dist/SHA256SUMS.
// --skip-web-build reuses app/build/web (and the whiteboard bundle in it) instead of building it.
//
// Versions: a release is named after server/pubspec.yaml's major.minor plus the number of commits
// on main (0.1.68, tagged v0.1.68), so bump the pubspec's version to start a new minor. Without
// --version, that's what this works out from the checkout (fetch the whole history for the count).
// The version is compiled into the binary (-Dversion=0.1.68). Needs the Flutter SDK on PATH (its
// `dart` runs this) and git; no Node.js.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';

final _root = File.fromUri(Platform.script).parent.parent.path;
String _p(List<String> parts) => parts.join(Platform.pathSeparator);

const _defaultRepo = 'AgentSystemLabs/agent-office';

Future<void> main(List<String> argv) async {
  final args = _parse(argv);
  final dart = Platform.resolvedExecutable;
  final version = args.version ?? _versionFromCheckout();
  final repo = args.repo ?? _repoFromCheckout();
  final platform = currentPlatform();
  _say('Building Agent Office v$version for ${platform.os}-${platform.arch} ($repo)');

  final web = _p([_root, 'app', 'build', 'web']);
  if (!args.skipWebBuild) {
    await _run(
        dart,
        [
          'run',
          _p([_root, 'tool', 'build_whiteboard.dart'])
        ],
        cwd: _root);
    await _run(_flutter(), ['build', 'web', '--release', '--no-web-resources-cdn', '--no-wasm-dry-run'],
        cwd: _p([_root, 'app']));
  }
  if (!File(_p([web, 'index.html'])).existsSync()) _die('$web/index.html is missing (build the client first)');

  final out = Directory(_p([_root, 'dist', 'agent-office']));
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync(recursive: true);

  final server = _p([_root, 'server']);
  await _run(dart, ['pub', 'get'], cwd: server);
  await _run(
      dart,
      [
        'compile',
        'exe',
        '-Dversion=$version',
        _p(['bin', 'agent_office.dart']),
        '-o',
        _p([out.path, 'agent-office']),
      ],
      cwd: server);

  // Everything but the engine's debug symbols, which only a debugger reads.
  _copyTree(Directory(web), Directory(_p([out.path, 'web'])), skip: (name) => name.endsWith('.symbols'));

  final head = _git(['log', '-1', '--format=%H%x00%s%x00%cI', 'HEAD'])?.split('\u0000');
  final info = <String, Object?>{
    'repo': repo,
    'tag': 'v$version',
    'os': platform.os,
    'arch': platform.arch,
    if (head != null && head.length == 3) ...{'commit': head[0], 'subject': head[1], 'date': head[2]},
  };
  File(_p([out.path, 'install.json'])).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(info)}\n');
  _say('Built ${_rel(out.path)}');

  if (args.pack) {
    final name = 'agent-office-${platform.os}-${platform.arch}.tar.gz';
    final tarball = File(_p([_root, 'dist', name]));
    if (tarball.existsSync()) tarball.deleteSync();
    // COPYFILE_DISABLE keeps macOS's tar from adding ._ resource files.
    await _run(
        'tar',
        [
          '-czf',
          tarball.path,
          '-C',
          _p([_root, 'dist']),
          'agent-office'
        ],
        cwd: _root,
        environment: {'COPYFILE_DISABLE': '1'});
    final sum = (await sha256.bind(tarball.openRead()).first).toString();
    // One line per tarball, the format `sha256sum -c` reads; the release job concatenates them.
    File(_p([_root, 'dist', 'SHA256SUMS'])).writeAsStringSync('$sum  $name\n');
    _say('Packed ${_rel(tarball.path)} (sha256 $sum)');
  }
}

class _Args {
  bool pack = false;
  bool skipWebBuild = false;
  String? version;
  String? repo;
}

_Args _parse(List<String> argv) {
  final a = _Args();
  for (var i = 0; i < argv.length; i++) {
    String value() => i + 1 < argv.length ? argv[++i] : _die('${argv[i]} needs a value');
    switch (argv[i]) {
      case '--pack':
        a.pack = true;
      case '--skip-web-build':
        a.skipWebBuild = true;
      case '--version':
        a.version = value().replaceFirst(RegExp('^v'), '');
      case '--repo':
        a.repo = value();
      case '-h' || '--help':
        stdout.writeln(
            'usage: dart run tool/build.dart [--pack] [--version <x.y.z>] [--repo <owner/name>] [--skip-web-build]');
        exit(0);
      default:
        _die('unknown option ${argv[i]} (see --help)');
    }
  }
  if (a.version != null && !RegExp(r'^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$').hasMatch(a.version!)) {
    _die('not a version: ${a.version}');
  }
  if (a.repo != null && !_repoPattern.hasMatch(a.repo!)) _die('--repo must be owner/name, got: ${a.repo}');
  return a;
}

final _repoPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

/// server/pubspec.yaml's major.minor plus the number of commits in the checkout.
String _versionFromCheckout() {
  final pubspec = File(_p([_root, 'server', 'pubspec.yaml'])).readAsStringSync();
  final m = RegExp(r'^version:\s*(\d+)\.(\d+)\.(\d+)', multiLine: true).firstMatch(pubspec);
  if (m == null) _die("server/pubspec.yaml has no version");
  final count = _git(['rev-list', '--count', 'HEAD']);
  return count == null ? '${m[1]}.${m[2]}.${m[3]}' : '${m[1]}.${m[2]}.$count';
}

/// The GitHub repo releases of this build come from: CI's, else the checkout's origin.
String _repoFromCheckout() {
  final env = Platform.environment['GITHUB_REPOSITORY'];
  if (env != null && _repoPattern.hasMatch(env)) return env;
  final origin = _git(['remote', 'get-url', 'origin']);
  final m = origin == null ? null : RegExp(r'github\.com[:/]([^/]+/[^/]+?)(\.git)?/?$').firstMatch(origin);
  return m?[1] ?? _defaultRepo;
}

String? _git(List<String> args) {
  try {
    final r = Process.runSync('git', args, workingDirectory: _root);
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  } on ProcessException {
    return null;
  }
}

/// The platform release assets are named after: linux or darwin, x64 or arm64.
({String os, String arch}) currentPlatform() => switch (Abi.current()) {
      Abi.linuxX64 => (os: 'linux', arch: 'x64'),
      Abi.linuxArm64 => (os: 'linux', arch: 'arm64'),
      Abi.macosX64 => (os: 'darwin', arch: 'x64'),
      Abi.macosArm64 => (os: 'darwin', arch: 'arm64'),
      final abi => _die('Agent Office is built for Linux and macOS on x64 and arm64, not $abi'),
    };

/// `flutter` from the SDK whose `dart` runs this, else the one on PATH.
String _flutter() {
  // <flutter>/bin/cache/dart-sdk/bin/dart
  final flutterBin = File(Platform.resolvedExecutable).parent.parent.parent.parent.path;
  final candidate = File(_p([flutterBin, 'flutter']));
  return candidate.existsSync() ? candidate.path : 'flutter';
}

void _copyTree(Directory from, Directory to, {required bool Function(String name) skip}) {
  to.createSync(recursive: true);
  for (final e in from.listSync(followLinks: false)) {
    final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (skip(name)) continue;
    final dest = _p([to.path, name]);
    if (e is Directory) {
      _copyTree(e, Directory(dest), skip: skip);
    } else if (e is File) {
      e.copySync(dest);
    }
  }
}

Future<void> _run(String cmd, List<String> args, {required String cwd, Map<String, String>? environment}) async {
  stderr.writeln('\$ $cmd ${args.join(' ')}');
  final Process p;
  try {
    p = await Process.start(cmd, args,
        workingDirectory: cwd, environment: environment, mode: ProcessStartMode.inheritStdio);
  } on ProcessException catch (e) {
    _die('could not run $cmd (${e.message}). Is it installed and on PATH?');
  }
  final code = await p.exitCode;
  if (code != 0) _die('$cmd ${args.take(2).join(' ')} failed (exit code $code)');
}

String _rel(String path) => path.startsWith('$_root/') ? path.substring(_root.length + 1) : path;

void _say(String msg) => stderr.writeln('build: $msg');

Never _die(String msg) {
  stderr.writeln('build: $msg');
  exit(1);
}
