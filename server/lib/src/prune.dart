import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'worktrees.dart';

final _help =
    '''agent-office prune — remove leftover worker worktrees and branches

Usage:
  agent-office prune [dir] [options]

Removes the worktrees under $worktreesDir/ and the office/* branches that
no worker of the office in [dir] (default: current directory) uses any more.
Anything with uncommitted changes, or with commits that no remote has, is kept
and listed, so nothing is lost by accident.

Options:
  -n, --dry-run   Show what would be removed and change nothing
  -f, --force     Remove leftovers even when they hold work
  -h, --help      Show this help
''';

/// `agent-office prune` ([argv] is what follows `prune`): exits 0 when done, 1 when the dir is not
/// a git repo, 2 for a usage error.
Future<int> prune(List<String> argv) async {
  var dir = Directory.current.path;
  var dryRun = false;
  var force = false;
  for (final a in argv) {
    if (a == '-h' || a == '--help') {
      stdout.write(_help);
      return 0;
    } else if (a == '-n' || a == '--dry-run') {
      dryRun = true;
    } else if (a == '-f' || a == '--force') {
      force = true;
    } else if (a.startsWith('-')) {
      stderr.writeln('agent-office prune: unknown option $a\n');
      stderr.write(_help);
      return 2;
    } else {
      dir = p.normalize(p.absolute(a));
    }
  }
  if (FileSystemEntity.typeSync(dir) == FileSystemEntityType.notFound) {
    stderr.writeln('agent-office prune: directory not found: $dir');
    return 2;
  }
  try {
    final r = Process.runSync('git', ['rev-parse', '--git-dir'], workingDirectory: dir);
    if (r.exitCode != 0) throw const FormatException();
  } catch (_) {
    stderr.writeln('agent-office prune: not a git repository: $dir');
    return 1;
  }

  // Workers the office still has, awake or asleep, keep theirs: send them home from the office instead.
  final ownerOfBranch = <String, String>{};
  final ownerOfPath = <String, String>{};
  try {
    final saved = jsonDecode(File(p.join(dir, '.agent-office', 'workers.json')).readAsStringSync());
    for (final w in saved as List) {
      if (w is! Map || w['worktree'] is! Map) continue;
      final wt = w['worktree'] as Map;
      final name = w['name'] is String ? w['name'] as String : 'a worker';
      if (wt['branch'] is String) ownerOfBranch[wt['branch'] as String] = name;
      if (wt['path'] is String) ownerOfPath[p.normalize(wt['path'] as String)] = name;
    }
  } catch (_) {
    // no saved workers
  }

  final trees = Worktrees(dir);
  final (:worktrees, :branches, :strays) = await trees.list();
  var removed = 0;
  var kept = 0;
  void line(String status, String what, String why) =>
      stdout.writeln('  ${status.padRight(12)} ${what.padRight(32)} $why');
  void keep(String what, String why) {
    kept++;
    line('kept', what, why);
  }

  Future<void> drop(String what, String why, Future<String?> Function() act) async {
    final err = dryRun ? null : await act();
    if (err != null) {
      kept++;
      line('failed', what, err);
    } else {
      removed++;
      line(dryRun ? 'would remove' : 'removed', what, why);
    }
  }

  stdout.writeln('\n  agent-office prune — $dir${dryRun ? ' (dry run)' : ''}\n');
  final withWorktree = <String>{};
  for (final wt in worktrees) {
    final branch = wt.branch;
    if (branch != null) withWorktree.add(branch);
    final ref = WorktreeRef(path: wt.path, branch: branch ?? wt.head);
    final label = branch ?? '${wt.path} (detached)';
    final byBranch = branch != null ? ownerOfBranch[branch] : null;
    final owner = byBranch != null && byBranch.isNotEmpty ? byBranch : ownerOfPath[p.normalize(wt.path)];
    if (owner != null && owner.isNotEmpty) {
      keep(label, "$owner's — send $owner home from the office to clean it up");
      continue;
    }
    final work = describeWork(await trees.inspect(ref));
    if (work.isNotEmpty && !force) {
      keep(label, '$work — --force removes it anyway');
      continue;
    }
    await drop(
      label,
      work.isNotEmpty ? '$work (forced)' : 'clean, nothing unpushed',
      () => trees.remove(ref, branch != null ? WorktreeCleanup.all : WorktreeCleanup.worktree),
    );
  }
  for (final branch in branches) {
    if (withWorktree.contains(branch)) continue;
    final owner = ownerOfBranch[branch];
    if (owner != null) {
      keep(branch, "$owner's — its worktree is gone, but the office still lists the worker");
      continue;
    }
    final work = describeWork(await trees.inspect(WorktreeRef(branch: branch)));
    if (work.isNotEmpty && !force) {
      keep(branch, '$work — --force removes it anyway');
      continue;
    }
    await drop(
      branch,
      work.isNotEmpty ? '$work (forced); its worktree was already gone' : 'branch only, its worktree was already gone',
      () => trees.remove(WorktreeRef(branch: branch), WorktreeCleanup.all),
    );
  }
  for (final rel in strays) {
    final owner = ownerOfPath[p.normalize(rel)];
    if (owner != null) {
      keep(rel, "$owner's folder");
      continue;
    }
    if (!force) {
      keep(rel, 'a folder git does not list as a worktree — --force deletes it');
      continue;
    }
    await drop(rel, 'a folder git did not list as a worktree (forced)', () async {
      try {
        await Directory(p.join(dir, rel)).delete(recursive: true);
        return null;
      } on PathNotFoundException {
        return null;
      } catch (err) {
        return gitError(err);
      }
    });
  }
  if (worktrees.isEmpty && branches.isEmpty && strays.isEmpty) {
    stdout.writeln('  nothing under $worktreesDir/ and no office/* branches — all clean');
  }
  stdout.writeln('\n  $removed ${dryRun ? 'to remove' : 'removed'}, $kept kept.\n');
  return 0;
}
