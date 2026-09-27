import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'github.dart';

/// A floor as floors.json keeps it.
class FloorDef {
  FloorDef({
    required this.id,
    required this.name,
    this.repo,
    required this.dir,
    required this.palette,
    required this.addedBy,
    required this.addedAt,
  });

  final String id;
  final String name;

  /// owner/name on GitHub.
  final String? repo;
  final String dir;
  final int palette;
  final String addedBy;
  final int addedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'repo': ?repo,
    'dir': dir,
    'palette': palette,
    'addedBy': addedBy,
    'addedAt': addedAt,
  };
}

/// How long the list of repositories `gh` can see is reused before it's asked again.
const int _reposTtlMs = 5 * 60000;
const int _maxRepos = 1000;
const Duration _cloneTimeout = Duration(minutes: 30);

final RegExp _idRe = RegExp(r'^[a-z0-9-]{1,40}$');

int _now() => DateTime.now().millisecondsSinceEpoch;

String _resolve(String dir) => p.normalize(p.absolute(dir));

/// The floors of the building, saved in `<office>/.agent-office/floors.json`: which projects there are,
/// where their checkouts live, and how each floor is painted. New floors are cloned with the office
/// machine's `gh` login into `<projects>/<owner>/<repo>`.
class Building {
  Building(
    /// The office's own data folder; `gh` runs there, since the projects folder may not exist yet.
    this._dataDir,

    /// Where new floors are cloned.
    this.projectsDir,
  ) : _file = p.join(_dataDir, 'floors.json') {
    _load();
  }

  final String _dataDir;
  final String projectsDir;
  final String _file;
  final List<FloorDef> _defs = [];

  /// Floors being cloned, by lower-cased repo. Not saved until the clone is there.
  final Map<String, FloorDef> _cloning = {};
  ({int at, Future<List<RepoChoice>> repos})? _repoCache;

  List<FloorDef> list() => _defs;

  /// Floors on their way: shown in the elevator, but nobody can ride there yet.
  List<FloorDef> pending() => [..._cloning.values];

  /// Makes the checkout the office was started in a floor, if it isn't one yet. It's the office's own
  /// project: `agent-office <dir>` has always meant that one.
  FloorDef ensureLocal(String dir, String by) {
    final abs = _resolve(dir);
    for (final d in _defs) {
      if (_resolve(d.dir) == abs) return d;
    }
    // Named after its folder, as the office always called it.
    final def = _newDef(p.basename(abs), originRepo(abs), abs, by);
    _defs.insert(0, def);
    _save();
    return def;
  }

  /// Clones a repository into the projects folder and adds it as a floor. `started` hears about the
  /// floor as soon as the clone begins; resolves to the finished floor, or to why there's none. A
  /// checkout that's already where the clone would go is used as it is.
  Future<({FloorDef? floor, String? error})> add(String input, String by, void Function(FloorDef def) started) async {
    ({FloorDef? floor, String? error}) fail(String e) => (floor: null, error: e);
    final wanted = normalizeRepo(input);
    if (wanted == null) return fail('Pick a repository, or type it as owner/name');
    if (_defs.any((d) => sameRepo(d.repo, wanted))) return fail('$wanted already has a floor');
    if (_cloning.containsKey(wanted.toLowerCase())) return fail('$wanted is already being cloned');
    if (_defs.length + _cloning.length >= maxFloors) return fail('The building is full ($maxFloors floors)');
    // Asking GitHub first says whether this login can see it at all, and gets the name's real case.
    String repo;
    try {
      final view = jsonDecode(await gh(['repo', 'view', wanted, '--json', 'nameWithOwner'], _dataDir, 30000));
      repo = normalizeRepo(view is Map ? view['nameWithOwner'] : null) ?? wanted;
    } catch (err) {
      return fail("Couldn't find $wanted on GitHub: ${err is GhError ? err.message : err}");
    }
    final key = repo.toLowerCase();
    if (_defs.any((d) => sameRepo(d.repo, repo))) return fail('$repo already has a floor');
    if (_cloning.containsKey(key)) return fail('$repo is already being cloned');
    final [owner, name] = repo.split('/');
    final dest = p.join(projectsDir, owner, name);
    if (_defs.any((d) => _resolve(d.dir) == dest)) return fail('$dest is already a floor');
    final def = _newDef(name, repo, dest, by);
    _cloning[key] = def;
    started(def);
    try {
      final err = await _cloneInto(repo, dest);
      if (err != null) return fail(err);
    } finally {
      _cloning.remove(key);
    }
    _defs.add(def);
    _save();
    return (floor: def, error: null);
  }

  /// Repositories the office's `gh` login can clone, most recently pushed first.
  Future<List<RepoChoice>> repos([bool refresh = false]) {
    final cached = _repoCache;
    if (cached != null && !refresh && _now() - cached.at < _reposTtlMs) return cached.repos;
    final repos = _listRepos(_dataDir);
    _repoCache = (at: _now(), repos: repos);
    // A failure is worth asking again next time, not keeping for five minutes.
    repos.then(
      (_) {},
      onError: (Object _) {
        if (identical(_repoCache?.repos, repos)) _repoCache = null;
      },
    );
    return repos;
  }

  FloorDef _newDef(String name, String? repo, String dir, String by) {
    final all = [..._defs, ..._cloning.values];
    final taken = {for (final d in all) d.id};
    var base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (base.length > 32) base = base.substring(0, 32);
    if (base.isEmpty) base = 'floor';
    var id = base;
    for (var n = 2; taken.contains(id); n++) {
      id = '$base-$n';
    }
    // The first look nobody has, so floors side by side never match; then round again.
    final used = {for (final d in all) d.palette};
    var free = -1;
    for (var i = 0; i < floorPalettes.length; i++) {
      if (!used.contains(i)) {
        free = i;
        break;
      }
    }
    final palette = free >= 0 ? free : all.length % floorPalettes.length;
    return FloorDef(id: id, name: name, repo: repo, dir: dir, palette: palette, addedBy: by, addedAt: _now());
  }

  void _load() {
    final file = File(_file);
    if (!file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync());
      final ids = <String>{};
      for (final s in saved is List ? saved : const []) {
        if (s is! Map) continue;
        final id = s['id'];
        final dir = s['dir'];
        if (id is! String || !_idRe.hasMatch(id) || ids.contains(id) || dir is! String || !p.isAbsolute(dir)) continue;
        ids.add(id);
        final name = s['name'];
        final palette = s['palette'];
        _defs.add(
          FloorDef(
            id: id,
            name: name is String && name.isNotEmpty
                ? (name.length > 100 ? name.substring(0, 100) : name)
                : p.basename(dir),
            repo: normalizeRepo(s['repo']),
            dir: dir,
            palette: palette is num && palette == palette.truncate() && palette >= 0 ? palette.toInt() : 0,
            addedBy: s['addedBy'] is String ? s['addedBy'] as String : '?',
            addedAt: s['addedAt'] is num ? (s['addedAt'] as num).toInt() : _now(),
          ),
        );
      }
    } catch (err) {
      stderr.writeln("agent-office: $_file couldn't be read, so the building starts empty: $err");
    }
  }

  void _save() {
    try {
      _writePrivate(_file, const JsonEncoder.withIndent('  ').convert([for (final d in _defs) d.toJson()]));
    } catch (err) {
      stderr.writeln("agent-office: couldn't save the floors: $err");
    }
  }
}

/// Writes [text] to [file] readable by this user only: to `<file>.tmp` first, then moved into place.
void _writePrivate(String file, String text) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(text);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', tmp]);
    } catch (_) {
      // no chmod: the folder around it is private anyway
    }
  }
  File(tmp).renameSync(file);
}

final RegExp _githubUrl = RegExp(r'github\.com[/:]', caseSensitive: false);

/// The GitHub repository a checkout's origin points at.
String? originRepo(String dir) {
  try {
    final r = Process.runSync('git', ['remote', 'get-url', 'origin'], workingDirectory: dir);
    if (r.exitCode != 0) return null;
    final url = '${r.stdout}'.trim();
    return _githubUrl.hasMatch(url) ? normalizeRepo(url) : null;
  } catch (_) {
    return null;
  }
}

/// Clones `repo` to `dest`, or checks that what's already there is that repository. Resolves to an error, if any.
Future<String?> _cloneInto(String repo, String dest) async {
  final type = FileSystemEntity.typeSync(dest);
  if (type != FileSystemEntityType.notFound) {
    if (type != FileSystemEntityType.directory) return "$dest is already there and isn't a folder";
    if (Directory(dest).listSync().isNotEmpty) {
      // Cloned before (a floor that was taken off the list, or by hand): move back in.
      return sameRepo(originRepo(dest), repo)
          ? null
          : "$dest already exists and isn't a checkout of $repo — move it out of the way first";
    }
  }
  try {
    Directory(p.dirname(dest)).createSync(recursive: true);
  } catch (err) {
    return "Couldn't make ${p.dirname(dest)}: ${err is FileSystemException ? err.message : err}";
  }
  try {
    final proc = await Process.start('gh', ['repo', 'clone', repo, dest], workingDirectory: p.dirname(dest));
    var killed = false;
    final timer = Timer(_cloneTimeout, () {
      killed = true;
      proc.kill();
    });
    final out = proc.stdout.drain<void>();
    final err = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    final code = await proc.exitCode;
    timer.cancel();
    await out;
    final stderrText = await err;
    if (code == 0 && !killed) return null;
    final raw = stderrText.isNotEmpty ? stderrText : 'Command failed: gh repo clone $repo $dest';
    final lines = raw.trim().split('\n').where((l) => l.isNotEmpty).toList();
    final why = lines.sublist(lines.length > 2 ? lines.length - 2 : 0).join(' ');
    return "Couldn't clone $repo: ${why.isNotEmpty ? why : 'gh failed'}";
  } on ProcessException catch (e) {
    return "Couldn't clone $repo: ${e.errorCode == 2 ? 'spawn gh ENOENT' : e.message}";
  }
}

Future<List<RepoChoice>> _listRepos(String cwd) async {
  final out = await gh(
    [
      'api',
      '--paginate',
      'user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member',
      '--jq',
      '.[] | {name: .full_name, description: (.description // ""), private: .private, pushedAt: .pushed_at}',
    ],
    cwd,
    90000,
  );
  final repos = <RepoChoice>[];
  final seen = <String>{};
  for (final line in out.split('\n')) {
    if (line.trim().isEmpty) continue;
    try {
      final r = jsonDecode(line);
      if (r is Map) {
        final name = normalizeRepo(r['name']);
        if (name != null && seen.add(name.toLowerCase())) {
          final description = r['description'];
          final pushedAt = r['pushedAt'];
          repos.add(
            RepoChoice(
              name: name,
              description: description is String && description.isNotEmpty
                  ? (description.length > 200 ? description.substring(0, 200) : description)
                  : null,
              private: r['private'] == true,
              pushedAt: pushedAt is String ? pushedAt : null,
            ),
          );
        }
      }
    } catch (_) {
      // not a line of ours
    }
    if (repos.length >= _maxRepos) break;
  }
  repos.sort((a, b) => (b.pushedAt ?? '').compareTo(a.pushedAt ?? ''));
  return repos;
}
