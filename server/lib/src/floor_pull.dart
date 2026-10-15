// ⬇️ Pull latest: a floor's checkout brought up to date with its branch on GitHub, from the
// elevator. Fetch, then fast-forward only: a checkout with changes of its own, or one whose branch went
// another way, is left as it is and says why, never merged or reset.

import 'dart:async';
import 'dart:io';

/// What a pull did: [error] when it didn't, else how many commits came in (0: already up to date).
typedef PullResult = ({String branch, int commits, String? error});

/// Brings [dir]'s current branch up to date with its upstream (or `origin/<branch>`), fast-forward only.
/// With a [base] branch the checkout isn't on (🌿 develop, say), that branch is brought up to date
/// instead, without switching the checkout.
Future<PullResult> pullLatest(
  String dir, {
  String? base,
  Map<String, String>? env,
  Duration timeout = const Duration(minutes: 2),
}) async {
  final environment = {...?env, 'GIT_TERMINAL_PROMPT': '0'};
  Future<ProcessResult> git(List<String> args) =>
      Process.run('git', args, workingDirectory: dir, environment: environment).timeout(timeout);
  String out(ProcessResult r) => '${r.stdout}'.trim();
  String err(ProcessResult r) {
    final e = '${r.stderr}'.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    return e.isEmpty ? out(r) : e.last.replaceFirst(RegExp(r'^(fatal|error): '), '');
  }

  try {
    final head = await git(['rev-parse', '--abbrev-ref', 'HEAD']);
    if (head.exitCode != 0) return (branch: '', commits: 0, error: "It isn't a git checkout");
    final branch = out(head);
    if (branch == 'HEAD') return (branch: branch, commits: 0, error: 'It is on no branch (a detached HEAD)');
    final before = out(await git(['rev-parse', 'HEAD']));

    final fetch = await git(['fetch', '--prune', 'origin']);
    if (fetch.exitCode != 0) return (branch: branch, commits: 0, error: "Couldn't fetch from GitHub: ${err(fetch)}");

    if (base != null && base.isNotEmpty && base != branch) {
      // The base isn't checked out here: move its branch along without touching the checkout.
      if ((await git(['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/$base'])).exitCode != 0) {
        return (branch: base, commits: 0, error: 'There is no $base on GitHub');
      }
      final had = await git(['rev-parse', '--verify', '--quiet', 'refs/heads/$base']);
      if (had.exitCode != 0) {
        final made = await git(['branch', '--track', base, 'origin/$base']);
        return (branch: base, commits: 0, error: made.exitCode == 0 ? null : err(made));
      }
      // A refspec fetch only fast-forwards, and refuses a branch checked out in a worktree.
      final moved = await git(['fetch', 'origin', 'refs/heads/$base:refs/heads/$base']);
      if (moved.exitCode != 0) {
        final ahead = (await git(['merge-base', '--is-ancestor', 'refs/heads/$base', 'origin/$base'])).exitCode != 0;
        return (
          branch: base,
          commits: 0,
          error: ahead ? '$base here has commits of its own that GitHub doesn\'t: pull it by hand' : err(moved),
        );
      }
      final n = await git(['rev-list', '--count', '${out(had)}..refs/heads/$base']);
      return (branch: base, commits: int.tryParse(out(n)) ?? 0, error: null);
    }

    final up = await git(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}']);
    var target = up.exitCode == 0 ? out(up) : 'origin/$branch';
    if ((await git(['rev-parse', '--verify', '--quiet', target])).exitCode != 0) {
      return (branch: branch, commits: 0, error: '$branch has no branch on GitHub to pull from');
    }
    if ((await git(['merge-base', '--is-ancestor', target, 'HEAD'])).exitCode == 0) {
      return (branch: branch, commits: 0, error: null);
    }
    if ((await git(['merge-base', '--is-ancestor', 'HEAD', target])).exitCode != 0) {
      return (
        branch: branch,
        commits: 0,
        error: '$branch has commits of its own that $target doesn\'t: pull it by hand',
      );
    }
    final merge = await git(['merge', '--ff-only', target]);
    if (merge.exitCode != 0) {
      final changed = out(await git(['status', '--porcelain', '--untracked-files=no'])).isNotEmpty;
      return (
        branch: branch,
        commits: 0,
        error: changed
            ? 'The checkout has changes of its own the pull would overwrite: commit or stash them first'
            : err(merge),
      );
    }
    final count = await git(['rev-list', '--count', '$before..HEAD']);
    return (branch: branch, commits: int.tryParse(out(count)) ?? 0, error: null);
  } on TimeoutException {
    return (branch: '', commits: 0, error: 'Git took too long (is GitHub reachable?)');
  } on ProcessException catch (e) {
    return (branch: '', commits: 0, error: "Couldn't run git: ${e.message}");
  }
}
