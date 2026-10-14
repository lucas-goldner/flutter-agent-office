// The words of the send-home dialog (see prompt.dart), apart so they are tested on the VM.

import 'package:office_shared/protocol.dart';

String plural(int count, String noun) => '$count $noun${count == 1 ? '' : 's'}';

const Map<WorktreeCleanup, String> kCleanupLabel = {
  WorktreeCleanup.all: 'Send home & delete both',
  WorktreeCleanup.worktree: 'Send home & delete worktree',
  WorktreeCleanup.keep: 'Send home',
};

/// The choices for a worktree: value, title, and the line under it. [across]: the folders of a worker
/// across repositories (its own floor's first), each a worktree on the same [branch].
List<(WorktreeCleanup, String, String)> cleanupChoices(String path, String branch, [List<String>? across]) =>
    across != null && across.length > 1
    ? [
        (
          WorktreeCleanup.all,
          'Delete the worktrees and their branch',
          'Removes its worktrees of ${across.join(', ')}, and $branch in each.',
        ),
        (
          WorktreeCleanup.worktree,
          'Delete the worktrees, keep the branch',
          '$branch stays in each for a pull request or a later checkout.',
        ),
        (
          WorktreeCleanup.keep,
          'Keep them all',
          'Leaves everything as it is; agent-office prune in each project tidies up later.',
        ),
      ]
    : [
        (WorktreeCleanup.all, 'Delete the worktree and its branch', 'Removes $path and $branch.'),
        (
          WorktreeCleanup.worktree,
          'Delete the worktree, keep the branch',
          '$branch stays for a pull request or a later checkout.',
        ),
        (WorktreeCleanup.keep, 'Keep both', 'Leaves everything as it is; agent-office prune tidies up later.'),
      ];

/// What the office found in the worktree, line by line, and whether deleting it would lose work. Across
/// repositories, a line for each worktree, named.
({List<String> lines, bool risky}) worktreeReport(WorktreeState s, String branch) {
  final repos = s.repos;
  if (repos == null || repos.isEmpty) return _describe(s, branch);
  final each = [for (final r in repos) _describe(r.state, branch, '${r.name}: ')];
  final lines = [for (final d in each) ...d.lines];
  final risky = each.any((d) => d.risky);
  if (s.error != null && lines.isEmpty) lines.add("Couldn't check the worktrees: ${s.error}.");
  return (lines: lines, risky: risky);
}

/// What deleting one worktree (and its branch) would lose, in a line or two.
({List<String> lines, bool risky}) _describe(WorktreeState s, String branch, [String prefix = '']) {
  if (s.error != null) return (lines: ["${prefix}Couldn't check the worktree: ${s.error}."], risky: true);
  final lines = <String>[];
  var risky = false;
  if (!s.exists) lines.add('${prefix}The worktree folder is already gone.');
  if (s.dirty > 0) {
    lines.add('⚠️ $prefix${plural(s.dirty, 'uncommitted change')} in the worktree — deleting it loses them.');
    risky = true;
  }
  if (s.unpushed > 0) {
    lines.add(
      '⚠️ $prefix${plural(s.unpushed, 'commit')} on $branch that no remote has — deleting the branch loses them.',
    );
    risky = true;
  } else if (s.ahead > 0) {
    lines.add('$prefix${plural(s.ahead, 'commit')} on $branch, all pushed or merged.');
  }
  if (lines.isEmpty) lines.add('${prefix}Nothing on the branch yet and a clean worktree: safe to delete.');
  return (lines: lines, risky: risky);
}
