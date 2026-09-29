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

  /// A new branch and worktree at the project's current HEAD. `from` is the branch the project was
  /// on, which the worker's pull request targets. Returns what went wrong as `error`.
  ({WorkerWorktree? worktree, String? error}) create(String slug) {
    try {
      final base = _gitSync(['rev-parse', 'HEAD']);
      final from = currentBranch();
      final rel = p.join(worktreesDir, slug);
      final branch = '$branchPrefix$slug';
      _gitSync(['worktree', 'add', '-b', branch, rel, base]);
      return (worktree: WorkerWorktree(path: rel, branch: branch, base: base, from: from), error: null);
    } catch (err) {
      return (worktree: null, error: 'Could not create a git worktree: ${gitError(err)}');
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

  Future<String> _git(List<String> args, [String? cwd]) async {
    final proc = await Process.start('git', args, workingDirectory: cwd ?? _dir);
    proc.stdin.close().ignore();
    var timedOut = false;
    final timer = Timer(const Duration(seconds: 60), () {
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
