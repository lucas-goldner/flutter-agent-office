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

/// A folder picked in ⚙️ Settings (or with --projects), as projects-folder.json keeps it; or the
/// checkout the office was started in, once it's been taken off the building (local-floor.json).
typedef _Picked = ({String dir, String by, int at});

/// The floors of the building, saved in `<office>/.agent-office/floors.json`: which projects there are,
/// where their checkouts live, and how each floor is painted. New floors are cloned with the office
/// machine's `gh` login into `<projects>/<owner>/<repo>`; the projects folder can be picked in ⚙️
/// Settings (kept in projects-folder.json).
class Building {
  Building(
    /// The office's own data folder; `gh` runs there, since the projects folder may not exist yet.
    this._dataDir,

    /// Where new floors are cloned unless another folder was picked.
    this._defaultProjectsDir,
  ) : _file = p.join(_dataDir, 'floors.json'),
      _pickedFile = p.join(_dataDir, 'projects-folder.json'),
      _localFile = p.join(_dataDir, 'local-floor.json') {
    _load();
    _picked = _loadPicked(_pickedFile);
    _localOff = _loadPicked(_localFile);
  }

  final String _dataDir;
  final String _defaultProjectsDir;
  final String _file;
  final String _pickedFile;
  final String _localFile;
  _Picked? _picked;
  final List<FloorDef> _defs = [];

  /// Floors being cloned, by lower-cased repo. Not saved until the clone is there.
  final Map<String, FloorDef> _cloning = {};
  ({int at, Future<List<RepoChoice>> repos})? _repoCache;

  /// The checkout the office was started in (see ensureLocal), and the repository it's a checkout of.
  ({String dir, String? repo})? _local;

  /// The floor that checkout is, while it is one.
  String? _localId;

  /// That checkout was taken off the building: a restart doesn't put it back.
  _Picked? _localOff;

  /// Where new floors are cloned. Floors already there stay where they are when it moves.
  String get projectsDir => _picked?.dir ?? _defaultProjectsDir;

  ProjectsDirState projectsDirState() =>
      ProjectsDirState(dir: tildify(projectsDir), custom: _picked != null, by: _picked?.by, at: _picked?.at);

  /// Clones new floors into [raw] from now on ('~' is the home folder; '' goes back to the default).
  /// Returns why it can't, if it can't.
  String? setProjectsDir(String raw, String by) {
    final text = raw.trim();
    var dir = _defaultProjectsDir;
    if (text.isNotEmpty) {
      final typed = _untildify(text);
      if (!p.isAbsolute(typed)) return 'Use a full path, like ~/Workspace';
      dir = _resolve(typed);
    }
    if (dir != _defaultProjectsDir) {
      final why = _unwritable(dir);
      if (why != null) return why;
      // Cloning into a project would nest checkouts inside its git tree.
      for (final d in _defs) {
        if (_within(dir, _resolve(d.dir))) {
          return "${tildify(dir)} is inside ${d.name}'s checkout — pick a folder outside every project";
        }
      }
    }
    final picked = dir == _defaultProjectsDir ? null : (dir: dir, by: by, at: _now());
    _picked = picked;
    try {
      _writePrivate(_pickedFile, _pickedJson(picked));
    } catch (err) {
      stderr.writeln("agent-office: couldn't save the projects folder: $err");
    }
    return null;
  }

  List<FloorDef> list() => _defs;

  /// Floors on their way: shown in the elevator, but nobody can ride there yet.
  List<FloorDef> pending() => [..._cloning.values];

  /// Makes the checkout the office was started in a floor, if it isn't one yet: `agent-office <dir>`
  /// has always meant that project. Once someone takes it off the building it stays off (the office
  /// still keeps its own data in it), until its repository is added again from the elevator.
  FloorDef? ensureLocal(String dir, String by) {
    final abs = _resolve(dir);
    FloorDef? known;
    for (final d in _defs) {
      if (_resolve(d.dir) == abs) {
        known = d;
        break;
      }
    }
    final local = (dir: abs, repo: known?.repo ?? originRepo(abs));
    _local = local;
    if (known != null) {
      _localId = known.id;
      if (_localOff != null) _setLocalOff(null);
      return known;
    }
    final off = _localOff;
    if (off != null && _resolve(off.dir) == abs) return null;
    // Named after its folder, as the office always called it.
    final def = _newDef(p.basename(abs), local.repo, abs, by);
    _defs.insert(0, def);
    _localId = def.id;
    _save();
    return def;
  }

  /// The office keeps its own data in this floor's checkout.
  bool isLocal(String id) => id == _localId;

  /// Takes a floor off the building. Its checkout stays where it is, with its workers, queue and
  /// pictures in its .agent-office folder: adding the repository again moves back in, as long as the
  /// checkout is still where the projects folder clones it (or it's the one the office was started
  /// in). Returns the floor, or why it can't.
  ({FloorDef? floor, String? error}) remove(String id, [String by = '?']) {
    FloorDef? def;
    for (final d in _defs) {
      if (d.id == id) {
        def = d;
        break;
      }
    }
    if (def == null) {
      return (
        floor: null,
        error: _cloning.values.any((d) => d.id == id)
            ? "That floor is still being cloned — take it off once it's there"
            : 'No such floor',
      );
    }
    _defs.remove(def);
    if (isLocal(id)) {
      _localId = null;
      _setLocalOff((dir: def.dir, by: by, at: _now()));
    }
    _save();
    return (floor: def, error: null);
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
    // The office's own checkout, taken off before: it moves back in where it is, not into a second clone.
    final home = _local;
    if (_localOff != null && home != null && sameRepo(home.repo, wanted) && Directory(home.dir).existsSync()) {
      final def = _newDef(p.basename(home.dir), home.repo, home.dir, by);
      started(def);
      _defs.add(def);
      _localId = def.id;
      _setLocalOff(null);
      _save();
      return (floor: def, error: null);
    }
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

  void _setLocalOff(_Picked? off) {
    _localOff = off;
    try {
      if (off != null) {
        _writePrivate(_localFile, _pickedJson(off));
      } else if (File(_localFile).existsSync()) {
        File(_localFile).deleteSync();
      }
    } catch (err) {
      stderr.writeln("agent-office: couldn't save $_localFile: $err");
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

String _pickedJson(_Picked? v) =>
    const JsonEncoder.withIndent('  ').convert(v == null ? {} : {'dir': v.dir, 'by': v.by, 'at': v.at});

_Picked? _loadPicked(String file) {
  try {
    final saved = jsonDecode(File(file).readAsStringSync());
    if (saved is Map && saved['dir'] is String && p.isAbsolute(saved['dir'] as String)) {
      return (
        dir: saved['dir'] as String,
        by: saved['by'] is String ? saved['by'] as String : '?',
        at: saved['at'] is num ? (saved['at'] as num).toInt() : _now(),
      );
    }
  } catch (_) {
    // never picked, or never taken off
  }
  return null;
}

String get _home => Platform.environment['HOME'] ?? '';

/// A path under the home folder as ~/…, for showing people.
String tildify(String path) {
  final home = _home;
  if (home.isEmpty) return path;
  return path == home || path.startsWith('$home${p.separator}') ? '~${path.substring(home.length)}' : path;
}

String _untildify(String path) =>
    path == '~' || path.startsWith('~/') ? p.join(_home, path.length > 2 ? path.substring(2) : '') : path;

/// [dir] is [parent] or somewhere under it.
bool _within(String dir, String parent) {
  final rel = p.relative(dir, from: parent);
  return rel == '.' || (rel != '..' && !rel.startsWith('..${p.separator}') && !p.isAbsolute(rel));
}

/// Why the office couldn't make checkouts under [dir], if it couldn't. It's made on the first clone,
/// so it needn't exist yet.
String? _unwritable(String dir) {
  var at = dir;
  while (FileSystemEntity.typeSync(at) == FileSystemEntityType.notFound && p.dirname(at) != at) {
    at = p.dirname(at);
  }
  if (!FileSystemEntity.isDirectorySync(at)) return "${tildify(at)} isn't a folder";
  // No access(2) in dart:io: try making (and removing) a file there.
  final probe = File(p.join(at, '.agent-office-write-test-${_now()}'));
  try {
    probe.writeAsStringSync('');
    probe.deleteSync();
  } catch (_) {
    return "The office can't write in ${tildify(at)}";
  }
  return null;
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
