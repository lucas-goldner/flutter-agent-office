import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:office_shared/protocol.dart';
import 'package:path/path.dart' as p;

/// The version compiled into the binary by tool/build.dart (`-Dversion=0.1.68`); empty under `dart run`.
const compiledVersion = String.fromEnvironment('version');

const checkEvery = Duration(minutes: 15);
const showChanges = 15;
const _defaultApi = 'https://api.github.com';

/// What a release install says about itself, in install.json next to the binary. tool/build.dart
/// writes it into every build, and install.sh (or the upgrader) records the repo it came from.
class InstallInfo {
  const InstallInfo({required this.repo, required this.tag, this.os, this.arch, this.commit, this.subject, this.date});

  /// The GitHub repo whose releases this came from, `owner/name`.
  final String repo;

  /// The release tag, `v0.1.68`.
  final String tag;
  final String? os;
  final String? arch;
  final String? commit;
  final String? subject;
  final String? date;

  static InstallInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final repo = j['repo'], tag = j['tag'];
    if (repo is! String || tag is! String || !_repoPattern.hasMatch(repo) || !validTag(tag)) return null;
    String? s(String k) => j[k] is String ? j[k] as String : null;
    return InstallInfo(
      repo: repo,
      tag: tag,
      os: s('os'),
      arch: s('arch'),
      commit: s('commit'),
      subject: s('subject'),
      date: s('date'),
    );
  }

  /// install.json in [dir], or null when it's missing or not one.
  static InstallInfo? read(String dir) {
    try {
      return fromJson(jsonDecode(File(p.join(dir, 'install.json')).readAsStringSync()));
    } on Object {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
    'repo': repo,
    'tag': tag,
    'os': ?os,
    'arch': ?arch,
    'commit': ?commit,
    'subject': ?subject,
    'date': ?date,
  };

  void write(String dir) {
    final file = File(p.join(dir, 'install.json'));
    File('${file.path}.tmp')
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(toJson())}\n')
      ..renameSync(file.path);
  }
}

final _repoPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

/// Whether [tag] is a release tag (`v0.1.68`), the same rule install.sh uses.
bool validTag(String tag) => RegExp(r'^v[0-9][0-9A-Za-z._+-]*$').hasMatch(tag);

/// Orders release versions (`v0.1.68` < `v0.1.100` < `v0.2.1`), numerically by dotted part; a
/// leading `v` and any `-pre`/`+build` suffix are ignored except to break ties (with a suffix first).
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    final core = v.replaceFirst(RegExp('^v'), '').split(RegExp('[-+]')).first;
    return core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  final sa = a.contains(RegExp('[-+]')), sb = b.contains(RegExp('[-+]'));
  return sa == sb ? 0 : (sa ? -1 : 1);
}

/// This machine as release assets name it: linux or darwin, x64 or arm64; null elsewhere.
({String os, String arch})? currentPlatform([Abi? abi]) => switch (abi ?? Abi.current()) {
  Abi.linuxX64 => (os: 'linux', arch: 'x64'),
  Abi.linuxArm64 => (os: 'linux', arch: 'arm64'),
  Abi.macosX64 => (os: 'darwin', arch: 'x64'),
  Abi.macosArm64 => (os: 'darwin', arch: 'arm64'),
  _ => null,
};

/// The release tarball's name for a platform.
String assetName(String os, String arch) => 'agent-office-$os-$arch.tar.gz';

const checksumsAsset = 'SHA256SUMS';

/// The download URL of the asset called [name] in a GitHub release's `assets`, or null.
String? pickAsset(Object? assets, String name) {
  if (assets is! List) return null;
  for (final a in assets) {
    final url = a is Map && a['name'] == name ? a['browser_download_url'] : null;
    if (url is String) return url;
  }
  return null;
}

/// Reads a `sha256sum` listing (`<hex>  <name>`, or `<hex> *<name>` for binary mode) into name -> hex.
Map<String, String> parseChecksums(String text) {
  final out = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final m = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$').firstMatch(line.trim());
    if (m != null) out[m[2]!.trim()] = m[1]!.toLowerCase();
  }
  return out;
}

Future<String> sha256OfFile(File file) async => (await sha256.bind(file.openRead()).first).toString();

/// Throws unless [file]'s sha256 is [expected].
Future<void> verifySha256(File file, String expected) async {
  final actual = await sha256OfFile(file);
  if (actual != expected.toLowerCase()) {
    throw StateError('${p.basename(file.path)} is corrupt: its sha256 is $actual, the release says $expected');
  }
}

/// Where the running binary is installed, and how a new version replaces it.
///
/// install.sh's layout: `<root>/versions/<tag>/agent-office` with `<root>/current` a symlink to
/// `versions/<tag>` (the systemd unit and ~/.local/bin/agent-office go through `current`). A new
/// version is unpacked next to the others and `current` is swung over to it with one rename.
///
/// Anything else is a standalone folder (a release tarball unpacked by hand, say /opt/agent-office):
/// the new version is unpacked next to it, then the two folders trade places with two renames.
class InstallLayout {
  InstallLayout._(this.dir, this.root, this.versioned);

  /// The folder of the running binary.
  final String dir;

  /// `<root>` of the versions layout, or the standalone folder's parent.
  final String root;
  final bool versioned;

  /// Where the new version is downloaded and unpacked, on the same filesystem as the install so
  /// swapping it in is a rename.
  String get stage => versioned ? p.join(root, 'versions', '.upgrade') : p.join(root, '.${p.basename(dir)}.upgrade');

  String get currentLink => p.join(root, 'current');

  static InstallLayout of(String exeDir) {
    final dir = p.normalize(p.absolute(exeDir));
    final versions = p.dirname(dir);
    final root = p.dirname(versions);
    final versioned = p.basename(versions) == 'versions' && FileSystemEntity.isLinkSync(p.join(root, 'current'));
    return InstallLayout._(dir, versioned ? root : p.dirname(dir), versioned);
  }

  /// Swaps [unpacked] (a release's `agent-office/` folder, inside [stage]) in as [tag]. Returns
  /// the folder the new binary is in. The running process keeps its (now moved or unlinked) files.
  String swapIn(String unpacked, String tag) {
    if (versioned) {
      final dest = p.join(root, 'versions', tag);
      if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
        // A copy from an earlier attempt; the one just verified wins.
        Directory(dest).renameSync(p.join(stage, 'old-$tag'));
      }
      Directory(unpacked).renameSync(dest);
      final next = Link(p.join(root, 'current.next'));
      if (next.existsSync() ||
          FileSystemEntity.typeSync(next.path, followLinks: false) != FileSystemEntityType.notFound) {
        next.deleteSync();
      }
      next.createSync(p.join('versions', tag));
      next.renameSync(currentLink); // rename(2) replaces the old link in one step
      return dest;
    }
    final old = p.join(stage, 'old');
    if (Directory(old).existsSync()) Directory(old).deleteSync(recursive: true);
    Directory(dir).renameSync(old);
    try {
      Directory(unpacked).renameSync(dir);
    } on Object {
      Directory(old).renameSync(dir); // put the running version back
      rethrow;
    }
    return dir;
  }
}

/// Lets an office installed from a GitHub release upgrade itself from the UI. Every 15 minutes it
/// asks GitHub for the newest release of the repo it came from and lists the commits since the
/// running one. Upgrading downloads this platform's tarball next to the install (the office keeps
/// working meanwhile, and a failed download changes nothing), checks it against the release's
/// SHA256SUMS, swaps it in, and then calls [restart] so the office exits and systemd starts the
/// new version.
class Upgrader {
  Upgrader(
    this._emit,
    this._restart, {
    String? exeDir,
    Map<String, String>? environment,
    String? apiBase,
    Duration firstCheck = const Duration(seconds: 10),
    Duration restartDelay = const Duration(milliseconds: 1500),
    Abi? abi,
  }) : _restartDelay = restartDelay,
       _env = environment ?? Platform.environment {
    final dir = exeDir ?? p.dirname(Platform.resolvedExecutable);
    _apiBase = (apiBase ?? _env['AGENT_OFFICE_GITHUB_API'] ?? _defaultApi).replaceFirst(RegExp(r'/+$'), '');
    _install = InstallInfo.read(dir);
    _layout = InstallLayout.of(dir);
    _platform = currentPlatform(abi);
    version =
        _install?.tag.replaceFirst(RegExp('^v'), '') ??
        (compiledVersion.isNotEmpty ? compiledVersion : (_gitSha(dir) ?? '0.0.0'));
    final current = _install == null
        ? null
        : VersionInfo(
            sha: _install!.tag,
            subject: _install!.subject ?? 'Agent Office ${_install!.tag}',
            date: _install!.date ?? '',
          );
    // Only deploy/aws.sh's systemd unit sets this, and it restarts the office whenever it exits.
    final enabled = _env['AGENT_OFFICE_SELF_UPDATE'] == '1' && _install != null && _platform != null;
    _state = UpgradeState(available: enabled, current: current, phase: UpgradePhase.idle);
    if (!enabled) return;
    _cleanUp();
    _timer = Timer.periodic(checkEvery, (_) => unawaited(check()));
    _first = Timer(firstCheck, () => unawaited(check()));
  }

  final void Function(UpgradeState state) _emit;
  final void Function() _restart;
  final Duration _restartDelay;
  final Map<String, String> _env;
  late final String _apiBase;
  InstallInfo? _install;
  late final InstallLayout _layout;
  late final ({String os, String arch})? _platform;

  /// What the running server is: its release version (`0.1.68`), else the checkout's commit.
  late final String version;

  late UpgradeState _state;
  UpgradeState get state => _state;

  _Release? _latest;
  Future<void>? _checking;
  Timer? _timer, _first;

  void stop() {
    _timer?.cancel();
    _first?.cancel();
  }

  bool get _busy => _state.phase == UpgradePhase.building || _state.phase == UpgradePhase.restarting;

  static const _keep = Object();

  void _set({
    Object? latest = _keep,
    Object? changes = _keep,
    Object? behind = _keep,
    Object? checking = _keep,
    Object? checkedAt = _keep,
    UpgradePhase? phase,
    Object? by = _keep,
    Object? error = _keep,
  }) {
    final s = _state;
    T? pick<T>(Object? v, T? old) => identical(v, _keep) ? old : v as T?;
    _state = UpgradeState(
      available: s.available,
      current: s.current,
      latest: pick(latest, s.latest),
      changes: pick(changes, s.changes),
      behind: pick(behind, s.behind),
      checking: pick(checking, s.checking),
      checkedAt: pick(checkedAt, s.checkedAt),
      phase: phase ?? s.phase,
      by: pick(by, s.by),
      error: pick(error, s.error),
    );
    _emit(_state);
  }

  /// Asks GitHub for the newest release.
  Future<void> check() {
    if (!_state.available || _busy) return Future.value();
    return _checking ??= _fetchLatest().whenComplete(() => _checking = null);
  }

  Future<void> _fetchLatest() async {
    final install = _install!;
    final platform = _platform!;
    _set(
      checking: true,
      phase: _state.phase == UpgradePhase.failed ? UpgradePhase.idle : null,
      error: _state.phase == UpgradePhase.failed ? null : _keep,
    );
    final client = _client();
    try {
      final rel = await _getJson(client, '$_apiBase/repos/${install.repo}/releases/latest');
      final tag = rel is Map ? rel['tag_name'] : null;
      if (tag is! String || !validTag(tag)) throw const FormatException("GitHub's answer has no release tag");
      final now = DateTime.now().millisecondsSinceEpoch;
      if (compareVersions(tag, install.tag) <= 0) {
        _latest = null;
        _set(checking: false, checkedAt: now, latest: null, changes: null, behind: null, error: null);
        return;
      }
      final asset = assetName(platform.os, platform.arch);
      final assets = (rel as Map)['assets'];
      final tarball = pickAsset(assets, asset);
      final sums = pickAsset(assets, checksumsAsset);
      if (tarball == null || sums == null) {
        _latest = null;
        _set(
          checking: false,
          checkedAt: now,
          latest: null,
          changes: null,
          behind: null,
          error: "The newest release, $tag, has no ${tarball == null ? asset : checksumsAsset} to upgrade to",
        );
        return;
      }
      // What changed. Without it (a tag GitHub can't compare, the rate limit) the upgrade still works.
      var changes = <UpgradeChange>[];
      int? behind;
      String subject = rel['name'] is String && (rel['name'] as String).isNotEmpty ? rel['name'] as String : tag;
      String date = rel['published_at'] is String ? rel['published_at'] as String : '';
      try {
        final cmp = await _getJson(client, '$_apiBase/repos/${install.repo}/compare/${install.tag}...$tag');
        if (cmp is Map && cmp['commits'] is List) {
          final commits = (cmp['commits'] as List).whereType<Map>().toList();
          changes = [
            for (final c in commits.reversed.take(showChanges))
              UpgradeChange(sha: _short(c['sha']), subject: _subject(c)),
          ];
          behind = cmp['total_commits'] is int ? cmp['total_commits'] as int : commits.length;
          if (commits.isNotEmpty) {
            subject = _subject(commits.last);
            final d = (commits.last['commit'] as Map?)?['committer'];
            if (d is Map && d['date'] is String) date = d['date'] as String;
          }
        }
      } on Object {
        // keep the release's own name and date
      }
      _latest = _Release(tag, tarball, sums, asset);
      _set(
        checking: false,
        checkedAt: now,
        latest: VersionInfo(sha: tag, subject: subject, date: date),
        behind: behind,
        changes: changes,
        error: null,
      );
    } on Object catch (e) {
      _set(
        checking: false,
        checkedAt: DateTime.now().millisecondsSinceEpoch,
        error: "Couldn't check for updates: ${_msg(e)}",
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Starts upgrading to the newest release. Returns why it can't, if it can't.
  Future<String?> start(String by) async {
    if (!_state.available) {
      return "This office can't upgrade itself (it wasn't installed from a release by deploy/aws.sh)";
    }
    if (_busy) return 'An upgrade is already running';
    await check();
    if (_busy) return 'An upgrade is already running';
    final rel = _latest;
    if (rel == null) return _state.error ?? 'The office is already up to date';
    _set(phase: UpgradePhase.building, by: by, error: null);
    unawaited(_build(rel));
    return null;
  }

  Future<void> _build(_Release rel) async {
    final stage = Directory(_layout.stage);
    final client = _client();
    try {
      if (stage.existsSync()) stage.deleteSync(recursive: true);
      stage.createSync(recursive: true);
      final tarball = File(p.join(stage.path, rel.asset));
      await _download(client, rel.tarball, tarball);
      final sums = parseChecksums(utf8.decode(await _getBytes(client, rel.checksums), allowMalformed: true));
      final want = sums[rel.asset];
      if (want == null) throw StateError("the release's $checksumsAsset has no line for ${rel.asset}");
      await verifySha256(tarball, want);

      final next = Directory(p.join(stage.path, 'next'))..createSync();
      await _run('tar', ['-xzf', tarball.path, '-C', next.path]);
      final unpacked = p.join(next.path, 'agent-office');
      for (final f in ['agent-office', p.join('web', 'index.html')]) {
        if (!File(p.join(unpacked, f)).existsSync()) throw StateError("the release tarball doesn't contain $f");
      }
      // It must run here: the right platform, and a binary that starts.
      final out = await _run(p.join(unpacked, 'agent-office'), ['--version'], timeout: const Duration(seconds: 30));
      final want2 = rel.tag.replaceFirst(RegExp('^v'), '');
      if (!out.contains(want2)) throw StateError('the new binary says it is "$out", not $want2');
      final shipped = InstallInfo.read(unpacked);
      InstallInfo(
        repo: _install!.repo,
        tag: rel.tag,
        os: shipped?.os ?? _platform!.os,
        arch: shipped?.arch ?? _platform!.arch,
        commit: shipped?.commit,
        subject: shipped?.subject,
        date: shipped?.date,
      ).write(unpacked);
      File(p.join(unpacked, '.installed')).writeAsStringSync('');
      _layout.swapIn(unpacked, rel.tag);
      tarball.deleteSync();
    } on Object catch (e) {
      try {
        if (stage.existsSync()) stage.deleteSync(recursive: true);
      } on Object {
        // best effort
      }
      _set(
        phase: UpgradePhase.failed,
        error: 'The upgrade failed, so the office stays on ${_state.current?.sha}.\n\n${_msg(e)}',
      );
      return;
    } finally {
      client.close(force: true);
    }
    _set(phase: UpgradePhase.restarting);
    // Give every browser a moment to hear about it, then hand over to the new version.
    Timer(_restartDelay, _restart);
  }

  /// Removes what's left of the last upgrade, and the versions it replaced, unless something still
  /// runs from them (the PTY host that keeps the workers alive, for one). Without pgrep, nothing.
  void _cleanUp() {
    try {
      final stage = Directory(_layout.stage);
      if (stage.existsSync()) stage.deleteSync(recursive: true);
      if (!_layout.versioned) return;
      final current = p.basename(p.normalize(p.join(_layout.root, Link(_layout.currentLink).targetSync())));
      for (final d in Directory(p.join(_layout.root, 'versions')).listSync().whereType<Directory>()) {
        final name = p.basename(d.path);
        if (!name.startsWith('v') || name == current || p.equals(d.path, _layout.dir)) continue;
        final r = Process.runSync('pgrep', ['-f', '--', '${d.path}/']);
        if (r.exitCode == 1) d.deleteSync(recursive: true);
      }
    } on Object {
      // best effort: install.sh prunes too
    }
  }

  // ---- HTTP -----------------------------------------------------------------------------------

  /// Honours HTTPS_PROXY and SSL_CERT_FILE (a CA bundle to trust on top of the system's).
  HttpClient _client() {
    final context = SecurityContext(withTrustedRoots: true);
    final ca = _env['SSL_CERT_FILE'];
    if (ca != null && File(ca).existsSync()) {
      try {
        context.setTrustedCertificates(ca);
      } on Object {
        // the system's roots will have to do
      }
    }
    return HttpClient(context: context)
      ..findProxy = ((uri) => HttpClient.findProxyFromEnvironment(uri, environment: _env))
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'agent-office/$version';
  }

  Future<HttpClientResponse> _open(HttpClient client, String url, {bool api = false}) async {
    final req = await client.getUrl(Uri.parse(url));
    if (api) {
      req.headers.set('accept', 'application/vnd.github+json');
      final token = _env['GITHUB_TOKEN'] ?? _env['GH_TOKEN'];
      if (token != null && token.isNotEmpty && url.startsWith(_apiBase)) {
        req.headers.set('authorization', 'Bearer $token');
      }
    }
    final res = await req.close().timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      await res.drain<void>();
      final limited = res.statusCode == 403 && res.headers.value('x-ratelimit-remaining') == '0';
      throw HttpException(limited ? "GitHub's rate limit is used up for now" : 'HTTP ${res.statusCode} from $url');
    }
    return res;
  }

  Future<Object?> _getJson(HttpClient client, String url) async =>
      jsonDecode(utf8.decode(await _collect(await _open(client, url, api: true))));

  Future<List<int>> _getBytes(HttpClient client, String url) async => _collect(await _open(client, url));

  Future<List<int>> _collect(HttpClientResponse res) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 60))) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  Future<void> _download(HttpClient client, String url, File to) async {
    final res = await _open(client, url);
    final sink = to.openWrite();
    try {
      await sink.addStream(res.timeout(const Duration(seconds: 60)));
    } finally {
      await sink.close();
    }
  }
}

class _Release {
  const _Release(this.tag, this.tarball, this.checksums, this.asset);
  final String tag, tarball, checksums, asset;
}

String _short(Object? sha) => sha is String && sha.length > 7 ? sha.substring(0, 7) : '$sha';

String _subject(Map commit) {
  final msg = (commit['commit'] as Map?)?['message'];
  return msg is String ? msg.split('\n').first : '';
}

String _msg(Object e) => switch (e) {
  HttpException(:final message) => message,
  StateError(:final message) => message,
  FormatException(:final message) => message,
  ProcessException(:final message) => message,
  SocketException(:final message) => message,
  TimeoutException() => 'GitHub took too long to answer',
  _ => '$e',
};

Future<String> _run(String cmd, List<String> args, {Duration timeout = const Duration(minutes: 2)}) async {
  final r = await Process.run(cmd, args).timeout(timeout);
  final out = '${r.stdout}'.trim();
  if (r.exitCode != 0) {
    final tail = '$out\n${r.stderr}'.trim().split('\n');
    throw StateError('$cmd ${args.first} failed: ${tail.skip(tail.length > 25 ? tail.length - 25 : 0).join('\n')}');
  }
  return out;
}

String? _gitSha(String dir) {
  try {
    final r = Process.runSync('git', ['rev-parse', '--short', 'HEAD'], workingDirectory: dir);
    return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
  } on Object {
    return null;
  }
}
