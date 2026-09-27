// The words of the send-home dialog (see prompt.dart), apart so they are tested on the VM.

import '../shared/protocol.dart';

String plural(int count, String noun) => '$count $noun${count == 1 ? '' : 's'}';

const Map<WorktreeCleanup, String> kCleanupLabel = {
  WorktreeCleanup.all: 'Send home & delete both',
  WorktreeCleanup.worktree: 'Send home & delete worktree',
  WorktreeCleanup.keep: 'Send home',
};

/// The choices for a worktree: value, title, and the line under it.
List<(WorktreeCleanup, String, String)> cleanupChoices(String path, String branch) => [
  (WorktreeCleanup.all, 'Delete the worktree and its branch', 'Removes $path and $branch.'),
  (WorktreeCleanup.worktree, 'Delete the worktree, keep the branch', '$branch stays for a pull request or a later checkout.'),
  (WorktreeCleanup.keep, 'Keep both', 'Leaves everything as it is; agent-office prune tidies up later.'),
];

/// What the office found in the worktree, line by line, and whether deleting it would lose work.
({List<String> lines, bool risky}) worktreeReport(WorktreeState s, String branch) {
  final lines = <String>[];
  var risky = false;
  if (s.error != null) {
    lines.add("Couldn't check the worktree: ${s.error}.");
    risky = true;
  } else {
    if (!s.exists) lines.add('The worktree folder is already gone.');
    if (s.dirty > 0) {
      lines.add('⚠️ ${plural(s.dirty, 'uncommitted change')} in the worktree — deleting it loses them.');
      risky = true;
    }
    if (s.unpushed > 0) {
      lines.add('⚠️ ${plural(s.unpushed, 'commit')} on $branch that no remote has — deleting the branch loses them.');
      risky = true;
    } else if (s.ahead > 0) {
      lines.add('${plural(s.ahead, 'commit')} on $branch, all pushed or merged.');
    }
    if (lines.isEmpty) lines.add('Nothing on the branch yet and a clean worktree: safe to delete.');
  }
  return (lines: lines, risky: risky);
}
