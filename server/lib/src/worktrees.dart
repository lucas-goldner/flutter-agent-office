import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

export 'package:office_shared/shared.dart' show WorktreeCleanup, WorktreeState;

/// Where the office keeps its workers' worktrees, relative to the project.
final worktreesDir = p.join('.agent-office', 'worktrees');

/// Their branches are `office/<worker>-<id>`.
const branchPrefix = 'office/';

class WorktreeRef {
  const WorktreeRef({this.path, required this.branch, this.base});

  /// Folder relative to the project dir; missing for a branch whose worktree is already gone.
  final String? path;
  final String branch;

  /// The commit it was branched from, when known.
  final String? base;
}

class ListedWorktree {
  ListedWorktree({required this.path, this.branch, this.head = ''});

  /// Relative to the project dir.
  final String path;
  String? branch;
  String head;
}

/// A git command that failed: what it printed on stderr, for [gitError].
class GitException implements Exception {
  GitException(this.message, [this.stderr = '']);

  final String message;
  final String stderr;

  @override
  String toString() => message;
}

/// Git plumbing for the worktrees the office makes for its workers: hiring, sending home and pruning.
class Worktrees {
  Worktrees(this._dir) : _root = _real(_dir);

  final String _dir;

  /// The project dir with symlinks resolved, so it compares with the paths git prints.
  final String _root;

  /// A fetch this recent is fresh enough for the next worktree: a burst of hires shares one.
  static const fetchFreshMs = 15000;
  static const fetchTimeoutMs = 15000;
  int _fetchedAt = 0;
  Future<void>? _fetching;

  /// The last fetch's error, so the office's log says it once rather than on every hire.
  String? _fetchError;

  /// A new branch and worktree, from the latest of the branch the project is on (see [_startPoint]).
  /// `from` is that branch, which the worker's pull request targets; [note] says when commits the
  /// project has were left out. Returns what went wrong as `error`.
  ({WorkerWorktree? worktree, String? note, String? error}) create(String slug) {
    try {
      final from = currentBranch();
      final start = _startPoint(from);
      final rel = p.join(worktreesDir, slug);
      final branch = '$branchPrefix$slug';
      _gitSync(['worktree', 'add', '-b', branch, rel, start.base]);
      return (
        worktree: WorkerWorktree(path: rel, branch: branch, base: start.base, from: from),
        note: start.note,
        error: null,
      );
    } catch (err) {
      return (worktree: null, note: null, error: 'Could not create a git worktree: ${gitError(err)}');
    }
  }

  /// Brings origin's copy of the branch the project is on up to date, so the next worktree starts
  /// from what's really there (a pull request merged since, say) rather than from a checkout nobody
  /// pulled. Completes either way: offline, or with no origin, worktrees start from what's here. Null
  /// when there's nothing to wait for (a fetch this recent, or no branch to fetch).
  Future<void>? fetch() {
    final fetching = _fetching;
    if (fetching != null) return fetching;
    if (DateTime.now().millisecondsSinceEpoch - _fetchedAt < fetchFreshMs) return null;
    final from = currentBranch();
    if (from == null || !_hasOrigin()) return null;
    return _fetching = () async {
      try {
        // Never stop to ask for a password: there's nobody at the office's terminal to type it.
        await _git(
          ['fetch', '--quiet', '--no-tags', 'origin', from],
          null,
          const Duration(milliseconds: fetchTimeoutMs),
          {'GIT_TERMINAL_PROMPT': '0'},
        );
        _fetchError = null;
      } catch (err) {
        // Its first complaint says what's wrong; the last line is advice about access rights.
        final printed = err is GitException ? err.stderr : '';
        final why =
            printed.split('\n').where((l) => RegExp(r'^(fatal|error):').hasMatch(l)).firstOrNull ?? gitError(err);
        if (why != _fetchError) {
          stderr.writeln(
            "agent-office: couldn't fetch origin/$from in $_dir, so new worktrees start from what's here: $why",
          );
        }
        _fetchError = why;
      } finally {
        _fetchedAt = DateTime.now().millisecondsSinceEpoch;
        _fetching = null;
      }
    }();
  }

  bool _hasOrigin() {
    try {
      return _gitSync(['remote', 'get-url', 'origin']).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Where a worktree starts: origin's copy of [from], which its pull request goes to, so it has every
  /// PR merged there even if nobody pulled them into the project. HEAD instead when it already has all
  /// of that (it's ahead with commits not pushed yet), or when origin doesn't have the branch.
  ({String base, String? note}) _startPoint(String? from) {
    final head = _gitSync(['rev-parse', 'HEAD']);
    if (from == null) return (base: head, note: null);
    String remote;
    try {
      remote = _gitSync(['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/$from^{commit}']);
    } catch (_) {
      return (base: head, note: null);
    }
    if (_isAncestor(remote, head)) return (base: head, note: null);
    if (_isAncestor(head, remote)) return (base: remote, note: null);
    // Both moved on: the PR goes to origin's, so start there and say what's left behind.
    final n = _number(_gitSync(['rev-list', '--count', head, '--not', remote]));
    return (
      base: remote,
      note: "starts from origin/$from, without the $n commit${n == 1 ? '' : 's'} on $from that origin doesn't have",
    );
  }

  bool _isAncestor(String a, String b) {
    try {
      _gitSync(['merge-base', '--is-ancestor', a, b]);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The branch the project is on, or null when HEAD is detached.
  String? currentBranch() {
    try {
      final b = _gitSync(['rev-parse', '--abbrev-ref', 'HEAD']);
      return b == 'HEAD' ? null : b;
    } catch (_) {
      return null;
    }
  }

  /// Where a branch still is: in the project, only on origin (it was pushed), or nowhere.
  LostBranch branchState(String branch) {
    bool has(String ref) {
      try {
        _gitSync(['rev-parse', '--verify', '--quiet', '$ref^{commit}']);
        return true;
      } catch (_) {
        return false;
      }
    }

    return has('refs/heads/$branch')
        ? LostBranch.here
        : has('refs/remotes/origin/$branch')
        ? LostBranch.origin
        : LostBranch.gone;
  }

  /// Puts back a worktree whose folder was deleted outside the office, where it was: on its branch
  /// while that's still here, else on origin's copy of it, else on the branch made again from where
  /// it started (`base`, or HEAD when even that commit is gone). Says which, or what went wrong.
  Future<({LostBranch? from, String? error})> restore(WorktreeRef wt) async {
    final path = wt.path;
    if (path == null) return (from: null, error: 'it has no folder to put back');
    final abs = p.join(_dir, path);
    try {
      // Git still lists the deleted folder, and won't check its branch out anywhere else while it does.
      await _git(['worktree', 'prune']);
      final from = branchState(wt.branch);
      switch (from) {
        case LostBranch.here:
          await _git(['worktree', 'add', abs, wt.branch]);
        case LostBranch.origin:
          await _git(['worktree', 'add', '-b', wt.branch, abs, 'refs/remotes/origin/${wt.branch}']);
        case LostBranch.gone:
          var base = 'HEAD';
          final saved = wt.base;
          if (saved != null) {
            try {
              await _git(['cat-file', '-e', '$saved^{commit}']);
              base = saved;
            } catch (_) {
              // that commit is gone too
            }
          }
          await _git(['worktree', 'add', '-b', wt.branch, abs, base]);
      }
      return (from: from, error: null);
    } catch (err) {
      return (from: null, error: gitError(err));
    }
  }

  /// What a worktree holds: uncommitted changes, commits since it was made, and the commits only it has.
  /// [landed] is a commit already delivered (the head of its merged pull request): it and the commits
  /// before it don't count as unpushed, even once GitHub has deleted the branch.
  Future<WorktreeState> inspect(WorktreeRef wt, [String? landed]) async {
    final abs = wt.path != null ? p.join(_dir, wt.path) : null;
    final exists = abs != null && FileSystemEntity.typeSync(abs) != FileSystemEntityType.notFound;
    var dirty = 0, ahead = 0, unpushed = 0;
    String? error;
    try {
      if (exists) dirty = (await _git(['status', '--porcelain'], abs)).split('\n').where((l) => l.isNotEmpty).length;
      // A commit this checkout never fetched (GitHub updated the branch itself) can't be left out.
      var known = false;
      if (landed != null && RegExp(r'^[0-9a-f]{40,64}$').hasMatch(landed)) {
        try {
          await _git(['cat-file', '-e', '$landed^{commit}']);
          known = true;
        } catch (_) {
          // not here
        }
      }
      // On no remote and not in the project's own checkout either: what deleting the branch would lose.
      unpushed = _number(
        await _git(['rev-list', '--count', wt.branch, '--not', 'HEAD', '--remotes', if (known) landed!]),
      );
      try {
        ahead = _number(await _git(['rev-list', '--count', wt.branch, '--not', wt.base ?? 'HEAD']));
      } catch (_) {
        ahead = unpushed;
      }
    } catch (err) {
      error = gitError(err);
    }
    return WorktreeState(exists: exists, dirty: dirty, ahead: ahead, unpushed: unpushed, error: error);
  }

  /// Deletes the worktree folder, and the branch too for 'all'. Returns what went wrong, if anything.
  Future<String?> remove(WorktreeRef wt, WorktreeCleanup cleanup) async {
    try {
      final path = wt.path;
      if (path != null) {
        final abs = p.join(_dir, path);
        if (FileSystemEntity.typeSync(abs) != FileSystemEntityType.notFound) {
          try {
            await _git(['worktree', 'remove', '--force', '--force', abs]);
          } catch (err) {
            // Git won't (a lock, a submodule), but it is the office's own folder: take it out ourselves.
            if (!owns(abs)) rethrow;
            try {
              await Directory(abs).delete(recursive: true);
            } on PathNotFoundException {
              // already gone
            }
          }
        }
      }
      // Forget worktrees whose folders are gone: this one, and any someone rm -rf'd by hand.
      await _git(['worktree', 'prune']);
      if (cleanup == WorktreeCleanup.all) await _git(['branch', '-D', wt.branch]);
      return null;
    } catch (err) {
      return gitError(err);
    }
  }

  /// The worktrees git has under .agent-office/worktrees, every office/* branch, and folders there git doesn't know.
  Future<({List<ListedWorktree> worktrees, List<String> branches, List<String> strays})> list() async {
    final home = p.join(_root, worktreesDir);
    final worktrees = <ListedWorktree>[];
    ListedWorktree? cur;
    for (final line in (await _git(['worktree', 'list', '--porcelain'])).split('\n')) {
      if (line.startsWith('worktree ')) {
        final abs = _real(line.substring('worktree '.length));
        cur = _within(home, abs) ? ListedWorktree(path: p.relative(abs, from: _root)) : null;
        if (cur != null) worktrees.add(cur);
      } else if (cur != null && line.startsWith('HEAD ')) {
        cur.head = line.substring('HEAD '.length);
      } else if (cur != null && line.startsWith('branch ')) {
        cur.branch = line.substring('branch '.length).replaceFirst(RegExp(r'^refs/heads/'), '');
      }
    }
    final branches = (await _git([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads/$branchPrefix',
    ])).split('\n').where((l) => l.isNotEmpty).toList();
    final known = {for (final w in worktrees) p.join(_root, w.path)};
    final strays = <String>[];
    if (FileSystemEntity.typeSync(home) != FileSystemEntityType.notFound) {
      for (final e in Directory(home).listSync(followLinks: false)) {
        final path = p.join(home, p.basename(e.path));
        if (!known.contains(path) && FileSystemEntity.isDirectorySync(path)) strays.add(p.relative(path, from: _root));
      }
    }
    return (worktrees: worktrees, branches: branches, strays: strays);
  }

  /// True for a folder inside .agent-office/worktrees, the only place this class deletes on its own.
  bool owns(String abs) => _within(p.join(_root, worktreesDir), _real(abs));

  String _gitSync(List<String> args, [String? cwd]) {
    final r = Process.runSync('git', args, workingDirectory: cwd ?? _dir);
    if (r.exitCode != 0) {
      throw GitException('Command failed: git ${args.join(' ')}', '${r.stderr}');
    }
    return '${r.stdout}'.trim();
  }

  Future<String> _git(
    List<String> args, [
    String? cwd,
    Duration timeout = const Duration(seconds: 60),
    Map<String, String>? environment,
  ]) async {
    final proc = await Process.start('git', args, workingDirectory: cwd ?? _dir, environment: environment);
    proc.stdin.close().ignore();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      proc.kill();
    });
    try {
      final out = proc.stdout.transform(utf8.decoder).join();
      final err = proc.stderr.transform(utf8.decoder).join();
      final code = await proc.exitCode;
      final stdout = await out, stderr = await err;
      if (code != 0 || timedOut) throw GitException('Command failed: git ${args.join(' ')}', stderr);
      return stdout.trim();
    } finally {
      timer.cancel();
    }
  }
}

int _number(String s) => int.tryParse(s.trim()) ?? 0;

/// Why deleting this would lose something ("2 uncommitted changes, 1 unpushed commit"), or '' when it wouldn't.
String describeWork(WorktreeState s) {
  if (s.error != null) return 'could not check it (${s.error})';
  final parts = <String>[];
  if (s.dirty > 0) parts.add('${s.dirty} uncommitted change${s.dirty == 1 ? '' : 's'}');
  if (s.unpushed > 0) parts.add('${s.unpushed} unpushed commit${s.unpushed == 1 ? '' : 's'}');
  return parts.join(', ');
}

/// The last line git printed, which is the one that says what's wrong.
String gitError(Object? err) {
  final String text;
  if (err is GitException) {
    text = err.stderr.isNotEmpty ? err.stderr : err.message;
  } else if (err is FileSystemException) {
    text = err.osError?.message ?? err.message;
  } else if (err is ProcessException) {
    text = err.message;
  } else {
    text = '$err';
  }
  final lines = text.trim().split('\n').where((l) => l.isNotEmpty);
  return lines.isEmpty ? 'git failed' : lines.last;
}

String _real(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return p.normalize(p.absolute(path));
  }
}

bool _within(String root, String path) {
  final rel = p.relative(path, from: root);
  return rel != '.' && rel.isNotEmpty && !rel.startsWith('..') && !p.isAbsolute(rel);
}
