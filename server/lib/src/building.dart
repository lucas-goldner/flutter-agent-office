import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'clone.dart';
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

/// A floor on its way: its clone, and who can stop it besides admins.
class _Pending {
  _Pending(this.def, {this.owner, this.empty = false});

  final FloorDef def;
  CloneRun? run;

  /// The account that added it.
  final String? owner;

  /// GitHub says the repository has no commits yet, so there's nothing to check out.
  final bool empty;
}

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
    this._defaultProjectsDir, {

    /// Clones run in this terminal (`agent-office setup`), showing git's own progress and asking
    /// there if ssh or git has a question, rather than watched by the office.
    this.terminal = false,

    /// How clones are watched (tests shorten these).
    this.cloneStall = cloneStallTime,
    this.cloneTick = const Duration(seconds: 1),
  }) : _file = p.join(_dataDir, 'floors.json'),
       _pickedFile = p.join(_dataDir, 'projects-folder.json'),
       _localFile = p.join(_dataDir, 'local-floor.json'),
       _clonesFile = p.join(_dataDir, 'cloning.json'),
       _logsDir = p.join(_dataDir, 'clones') {
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

  final bool terminal;
  final Duration cloneStall;
  final Duration cloneTick;

  /// Floors being cloned, by lower-cased repo. Not in floors.json until the clone is there, but in cloning.json.
  final Map<String, _Pending> _cloning = {};
  final String _clonesFile;

  /// Where clones write their progress.
  final String _logsDir;

  /// Hears when a clone gets further along.
  void Function()? _cloneChanged;
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
  List<FloorDef> pending() => [for (final x in _cloning.values) x.def];

  /// How a floor on its way is getting on, once git says.
  CloneProgress? cloneProgress(String id) => _pendingFloor(id)?.run?.progress;

  /// [fn] hears whenever a clone gets further along (at most once a second each).
  void watchClones(void Function() fn) => _cloneChanged = fn;

  /// Stops a floor's clone before it's there, if [may] lets whoever's asking stop one `owner` added.
  /// git tidies away what it had cloned, and add() resolves to [why]. Returns why it can't, if it can't.
  String? cancel(String id, String why, bool Function(String? owner) may) {
    final x = _pendingFloor(id);
    if (x == null) return _defs.any((d) => d.id == id) ? 'That floor is already there' : 'No such floor';
    if (!may(x.owner)) return 'Only admins, or whoever added it, can stop a floor on its way';
    final run = x.run;
    if (run == null) return "There's no clone to stop yet — try again in a moment";
    run.stop(why);
    return null;
  }

  /// Picks up the clones an office before this one left running (it restarted mid-clone): each goes
  /// on as a floor on its way, and [done] hears how it ended (the floor, or why there's none). One
  /// that finished with no office watching becomes its floor now.
  void resumeClones(void Function(FloorDef? floor, String? error) done) {
    for (final s in _loadClones()) {
      final repo = normalizeRepo(s.repo);
      if (repo == null || _defs.any((d) => sameRepo(d.repo, repo)) || _cloning.containsKey(repo.toLowerCase())) {
        dropLog(s.log);
        continue;
      }
      final def = _newDef(s.name, repo, s.dir, s.addedBy);
      final pending = _Pending(def, owner: s.owner, empty: s.empty);
      final run = CloneRun.adopt(
        s.pid,
        s.log,
        group: s.group,
        changed: () => _cloneChanged?.call(),
        stall: cloneStall,
        tick: cloneTick,
      );
      if (run == null) {
        dropLog(s.log);
        if (_checkoutAt(def.dir, repo, pending.empty) != null) {
          done(null, 'Cloning $repo stopped when the office restarted — add it again');
          continue;
        }
        _defs.add(def);
        _save();
        done(def, null);
        continue;
      }
      pending.run = run;
      _cloning[repo.toLowerCase()] = pending;
      unawaited(
        run.done.then((end) {
          final err = _settle(pending, end);
          _cloning.remove(repo.toLowerCase());
          _saveClones();
          if (err == null) {
            _defs.add(def);
            _save();
          }
          done(err == null ? def : null, err);
        }),
      );
    }
    _saveClones();
  }

  /// The office is closing: its clones stop, or with [keep] (a restart) carry on for the next office to pick up.
  void shutdown(bool keep) {
    for (final x in _cloning.values) {
      if (keep) {
        x.run?.release();
      } else {
        x.run?.stop('The office closed before the clone finished');
      }
    }
    if (keep) return;
    _cloning.clear();
    _saveClones();
  }

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
        error: _pendingFloor(id) != null
            ? "That floor is still being cloned — stop it, or take it off once it's there"
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
  /// checkout that's already where the clone would go is used as it is. [account] (whoever's adding it)
  /// can stop the clone, as admins can.
  Future<({FloorDef? floor, String? error})> add(
    String input,
    String by,
    void Function(FloorDef def) started, [
    String? account,
  ]) async {
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
    var empty = false;
    try {
      final view = jsonDecode(await gh(['repo', 'view', wanted, '--json', 'nameWithOwner,isEmpty'], _dataDir, 30000));
      repo = normalizeRepo(view is Map ? view['nameWithOwner'] : null) ?? wanted;
      empty = view is Map && view['isEmpty'] == true;
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
    final pending = _Pending(def, owner: account, empty: empty);
    _cloning[key] = pending;
    started(def);
    try {
      final err = await _clone(pending);
      if (err != null) return fail(err);
    } finally {
      _cloning.remove(key);
      _saveClones();
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

  /// Clones a floor on its way, or checks that what's already there is its repository. Resolves to an error, if any.
  Future<String?> _clone(_Pending x) async {
    final dest = x.def.dir;
    final repo = x.def.repo!;
    final there = _checkoutAt(dest, repo, x.empty);
    // Cloned before (a floor that was taken off the list, or by hand): move back in.
    if (there == null) return null;
    if (there != _none) return there;
    try {
      Directory(p.dirname(dest)).createSync(recursive: true);
    } catch (err) {
      return "Couldn't make ${p.dirname(dest)}: ${err is FileSystemException ? err.message : err}";
    }
    if (terminal) return _cloneHere(repo, dest);
    try {
      Directory(_logsDir).createSync(recursive: true);
      if (!Platform.isWindows) Process.runSync('chmod', ['700', _logsDir]);
    } catch (err) {
      return "Couldn't make $_logsDir: ${err is FileSystemException ? err.message : err}";
    }
    final started = await CloneRun.start(
      repo,
      dest,
      p.join(_logsDir, '${repo.replaceFirst('/', '__')}.log'),
      changed: () => _cloneChanged?.call(),
      stall: cloneStall,
      tick: cloneTick,
      gh: ghCommand,
    );
    final run = started.run;
    if (run == null) return started.error;
    x.run = run;
    _saveClones();
    return _settle(x, await run.done);
  }

  /// Whether a clone that ended left its checkout: an error if it didn't.
  String? _settle(_Pending x, CloneEnd end) {
    final run = x.run;
    if (run != null) dropLog(run.log);
    if (end.stopped != null) return end.stopped;
    // Its exit code isn't the word on it (it ran detached): the checkout is.
    if (_checkoutAt(x.def.dir, x.def.repo!, x.empty) == null) return null;
    return "Couldn't clone ${x.def.repo}: ${whyCloneFailed(end.output)}";
  }

  _Pending? _pendingFloor(String id) => _cloning.values.where((x) => x.def.id == id).firstOrNull;

  /// The clones under way, as cloning.json keeps them for the next office to pick up (see resumeClones).
  List<
    ({
      int pid,
      int? group,
      String log,
      String? owner,
      bool empty,
      String name,
      String? repo,
      String dir,
      String addedBy,
    })
  >
  _loadClones() {
    try {
      final saved = jsonDecode(File(_clonesFile).readAsStringSync());
      if (saved is! List) return const [];
      return [
        for (final s in saved)
          if (s is Map &&
              s['pid'] is int &&
              (s['pid'] as int) > 0 &&
              s['log'] is String &&
              // Its log is one of ours (it gets deleted), in .agent-office/clones.
              p.dirname(s['log'] as String) == _logsDir &&
              s['dir'] is String &&
              p.isAbsolute(s['dir'] as String) &&
              s['name'] is String)
            (
              pid: s['pid'] as int,
              group: s['group'] is int ? s['group'] as int : null,
              log: s['log'] as String,
              owner: s['owner'] is String ? s['owner'] as String : null,
              empty: s['empty'] == true,
              name: s['name'] as String,
              repo: s['repo'] is String ? s['repo'] as String : null,
              dir: s['dir'] as String,
              addedBy: s['addedBy'] is String ? s['addedBy'] as String : '?',
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Keeps the clones under way in cloning.json, so the next office can pick them up after a restart.
  void _saveClones() {
    final saved = [
      for (final x in _cloning.values)
        if (x.run case final run?)
          {...x.def.toJson(), 'pid': run.pid, 'group': run.group, 'log': run.log, 'owner': ?x.owner, 'empty': x.empty},
    ];
    try {
      if (saved.isNotEmpty) {
        _writePrivate(_clonesFile, const JsonEncoder.withIndent('  ').convert(saved));
      } else if (File(_clonesFile).existsSync()) {
        File(_clonesFile).deleteSync();
      }
    } catch (err) {
      stderr.writeln("agent-office: couldn't save $_clonesFile: $err");
    }
  }

  FloorDef _newDef(String name, String? repo, String dir, String by) {
    final all = [..._defs, for (final x in _cloning.values) x.def];
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

/// [_checkoutAt]: nothing is there yet.
const _none = 'none';

/// What's at [dest]: nothing yet ([_none]), a checkout of [repo] (null), or why it's in the way. A
/// clone that was cut off has its origin but no commit checked out; an [empty] repository has none to.
String? _checkoutAt(String dest, String repo, bool empty) {
  final type = FileSystemEntity.typeSync(dest);
  if (type == FileSystemEntityType.notFound) return _none;
  if (type != FileSystemEntityType.directory) return "$dest is already there and isn't a folder";
  if (Directory(dest).listSync().isEmpty) return _none;
  if (!sameRepo(originRepo(dest), repo)) {
    return "$dest already exists and isn't a checkout of $repo — move it out of the way first";
  }
  if (!empty && !_hasCommit(dest)) {
    return "$dest is a clone of $repo that didn't finish — delete that folder and add the floor again";
  }
  return null;
}

bool _hasCommit(String dir) {
  try {
    return Process.runSync('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'HEAD^{commit}',
        ], workingDirectory: dir).exitCode ==
        0;
  } catch (_) {
    return false;
  }
}

/// Clones [repo] to [dest] in this terminal: git shows its progress, and ssh or git can ask here.
/// Resolves to an error, if any.
Future<String?> _cloneHere(String repo, String dest) async {
  try {
    final proc = await Process.start(
      ghCommand,
      ['repo', 'clone', repo, dest],
      workingDirectory: p.dirname(dest),
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await proc.exitCode;
    return code == 0 ? null : "Couldn't clone $repo: gh failed (exit $code)";
  } on ProcessException catch (e) {
    return e.errorCode == 2 ? "The GitHub CLI (gh) isn't installed on this machine" : "Couldn't run gh: ${e.message}";
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
