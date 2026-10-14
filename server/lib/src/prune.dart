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
and listed, so nothing is lost by accident. A worker across several projects has
worktrees of them in its own floor's workspace: they're kept while the office
there still lists it, and pruning each project clears them out after.

Options:
  -n, --dry-run   Show what would be removed and change nothing
  -f, --force     Remove leftovers even when they hold work
  -h, --help      Show this help
''';

/// The workers an office keeps in a project's .agent-office/workers.json; none when it has no office there.
List<Map<dynamic, dynamic>> _savedWorkers(String dir) {
  try {
    final saved = jsonDecode(File(p.join(dir, '.agent-office', 'workers.json')).readAsStringSync());
    return saved is List
        ? [
            for (final w in saved)
              if (w is Map) w,
          ]
        : [];
  } catch (_) {
    return [];
  }
}

/// What's left in a workspace folder (a worker across repositories): 'empty' when it's only the brief
/// the office wrote there, or the names of folders in it that are still git worktrees (as a list).
Object? _workspaceLeft(String abs) {
  List<String> names;
  try {
    names = [for (final e in Directory(abs).listSync(followLinks: false)) p.basename(e.path)];
  } catch (_) {
    return null;
  }
  final trees = [
    for (final n in names)
      if (FileSystemEntity.typeSync(p.join(abs, n, '.git')) != FileSystemEntityType.notFound) n,
  ];
  if (trees.isNotEmpty) return trees;
  return names.every((n) => workspaceFiles.contains(n) && FileSystemEntity.isFileSync(p.join(abs, n))) ? 'empty' : null;
}

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
  for (final w in _savedWorkers(dir)) {
    if (w['worktree'] is! Map) continue;
    final wt = w['worktree'] as Map;
    final name = w['name'] is String ? w['name'] as String : 'a worker';
    if (wt['branch'] is String) ownerOfBranch[wt['branch'] as String] = name;
    if (wt['made'] is String) ownerOfBranch[wt['made'] as String] = name;
    if (wt['path'] is String) {
      ownerOfPath[p.normalize(wt['path'] as String)] = name;
      // Across repositories: the workspace folder its worktrees are in is its too.
      if (w['repos'] is List && (w['repos'] as List).isNotEmpty) {
        ownerOfPath[p.normalize(p.dirname(wt['path'] as String))] = name;
      }
    }
  }

  final trees = Worktrees(dir);
  final (:worktrees, :branches, :strays, :elsewhere) = await trees.list();
  // Workspaces a worktree was just taken out of: gone too once nothing but the brief is left.
  final emptied = <String>{};
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
    if (p.dirname(p.normalize(wt.path)) != p.normalize(worktreesDir)) emptied.add(p.dirname(wt.path));
  }
  // This project's worktrees in another floor's workspace, made for a worker there across repositories.
  for (final MapEntry(key: branch, value: abs) in elsewhere.entries) {
    withWorktree.add(branch);
    final at = abs.lastIndexOf('${p.separator}$worktreesDir${p.separator}');
    if (at < 0) {
      keep(branch, 'checked out at $abs');
      continue;
    }
    final office = abs.substring(0, at);
    final owner = _savedWorkers(office).where((w) {
      final wt = w['worktree'];
      final repos = w['repos'];
      return (wt is Map && wt['branch'] == branch) ||
          (repos is List && repos.any((r) => r is Map && r['branch'] == branch));
    }).firstOrNull;
    if (owner != null) {
      final name = owner['name'] is String ? owner['name'] as String : 'a worker';
      keep(branch, "$name's, in $abs — send $name home from the office there to clean it up");
      continue;
    }
    final ref = WorktreeRef(
      path: p.relative(abs, from: dir),
      branch: branch,
    );
    final work = describeWork(await trees.inspect(ref));
    if (work.isNotEmpty && !force) {
      keep(branch, '$work, in $abs — --force removes it anyway');
      continue;
    }
    await drop(
      branch,
      '${work.isNotEmpty ? '$work (forced)' : 'clean, nothing unpushed'}, in $abs',
      () => trees.remove(ref, WorktreeCleanup.all),
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
  for (final rel in [
    ...strays,
    ...emptied.where((e) => !strays.contains(e) && _workspaceLeft(p.join(dir, e)) == 'empty'),
  ]) {
    final owner = ownerOfPath[p.normalize(rel)];
    if (owner != null) {
      keep(rel, "$owner's folder");
      continue;
    }
    final left = _workspaceLeft(p.join(dir, rel));
    if (left is List) {
      // Worktrees of other projects: pruning those projects takes them out, with their own checks.
      keep(
        rel,
        'a workspace with worktrees of other projects in it (${left.join(', ')}) — run agent-office prune in those projects',
      );
      continue;
    }
    if (left == 'empty') {
      await drop(rel, 'an empty workspace', () async {
        try {
          await Directory(p.join(dir, rel)).delete(recursive: true);
          return null;
        } on PathNotFoundException {
          return null;
        } catch (err) {
          return gitError(err);
        }
      });
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
  if (worktrees.isEmpty && branches.isEmpty && strays.isEmpty && elsewhere.isEmpty) {
    stdout.writeln('  nothing under $worktreesDir/ and no office/* branches — all clean');
  }
  stdout.writeln('\n  $removed ${dryRun ? 'to remove' : 'removed'}, $kept kept.\n');
  return 0;
}
