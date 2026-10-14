// Upstream's tests/worktrees.test.ts: worktrees start from what's on GitHub (#170), and come back
// from where their branch still is (#197).
import 'dart:async';
import 'dart:io';

import 'package:agent_office_server/src/changes.dart';
import 'package:agent_office_server/src/worktrees.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A project cloned from a bare origin, plus a second clone standing in for GitHub: whatever it
/// pushes is a pull request merged there, which the project hasn't pulled (issue #119).
class Fixture {
  Fixture() : root = Directory.systemTemp.createTempSync('office-worktrees-').resolveSymbolicLinksSync() {
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    run(root, ['init', '-q', '--bare', '-b', 'main', origin]);
    run(root, ['clone', '-q', origin, dir]);
    run(dir, ['checkout', '-q', '-b', 'main']);
    File(p.join(dir, 'a.txt')).writeAsStringSync('a');
    run(dir, ['add', '.']);
    run(dir, ['commit', '-qm', 'a']);
    run(dir, ['push', '-q', '-u', 'origin', 'main']);
    run(root, ['clone', '-q', origin, github]);
  }

  final String root;
  String get origin => p.join(root, 'origin.git');
  String get dir => p.join(root, 'project');
  String get github => p.join(root, 'github');

  String run(String cwd, List<String> args) {
    final r = Process.runSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', ...args], workingDirectory: cwd);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
    return '${r.stdout}'.trim();
  }

  String git(List<String> args) => run(dir, args);

  String commitIn(String cwd, String file) {
    File(p.join(cwd, file)).writeAsStringSync(file);
    run(cwd, ['add', '.']);
    run(cwd, ['commit', '-qm', file]);
    return run(cwd, ['rev-parse', 'HEAD']);
  }

  String commit(String file) => commitIn(dir, file);

  String merge(String file) {
    run(github, ['pull', '-q', '--ff-only']);
    final sha = commitIn(github, file);
    run(github, ['push', '-q', 'origin', 'main']);
    return sha;
  }
}

void main() {
  test("a worktree starts from the PR merged on origin, not from the project's stale checkout", () async {
    final f = Fixture();
    final stale = f.git(['rev-parse', 'HEAD']);
    final merged = f.merge('fix.txt');
    final trees = Worktrees(f.dir);
    // Nothing fetched it yet: the project's main and its origin/main both still say `stale`.
    expect(f.git(['rev-parse', 'origin/main']), stale);
    final fetching = trees.fetch();
    expect(fetching, isNotNull, reason: 'fetches the first time');
    await fetching;
    expect(f.git(['rev-parse', 'origin/main']), merged);
    // A burst of hires shares that fetch.
    expect(trees.fetch(), isNull);
    final made = trees.create('rex-1');
    expect(made.error, isNull);
    expect(made.worktree!.base, merged);
    expect(made.worktree!.from, 'main');
    expect(made.note, isNull);
    expect(File(p.join(f.dir, made.worktree!.path, 'fix.txt')).existsSync(), isTrue, reason: 'it has the fix');
    // The project's own checkout is left where it was.
    expect(f.git(['rev-parse', 'HEAD']), stale);
  });

  test('a project ahead of origin (commits not pushed yet) still branches from its HEAD', () async {
    final f = Fixture();
    final local = f.commit('wip.txt');
    final trees = Worktrees(f.dir);
    await trees.fetch();
    final made = trees.create('rex-2');
    expect(made.error, isNull);
    expect(made.worktree!.base, local);
    expect(made.note, isNull);
  });

  test("when both moved on, it starts from origin's and says what it left out", () async {
    final f = Fixture();
    final merged = f.merge('fix.txt');
    f.commit('wip1.txt');
    f.commit('wip2.txt');
    final trees = Worktrees(f.dir);
    await trees.fetch();
    final made = trees.create('rex-3');
    expect(made.error, isNull);
    expect(made.worktree!.base, merged);
    expect(made.note, matches(RegExp(r'origin/main.*2 commits on main')));
  });

  test('without an origin, or offline, it branches from HEAD as before', () async {
    final f = Fixture();
    f.merge('fix.txt');
    f.git(['remote', 'set-url', 'origin', p.join(f.root, 'nowhere.git')]);
    final trees = Worktrees(f.dir);
    await trees.fetch();
    final made = trees.create('rex-4');
    expect(made.error, isNull);
    expect(made.worktree!.base, f.git(['rev-parse', 'HEAD']));
    f.git(['remote', 'remove', 'origin']);
    final again = Worktrees(f.dir);
    expect(again.fetch(), isNull, reason: 'nothing to fetch from');
    final other = again.create('rex-5');
    expect(other.error, isNull);
    expect(other.worktree!.base, f.git(['rev-parse', 'HEAD']));
  });

  test('on a detached HEAD there is no branch to fetch', () {
    final f = Fixture();
    f.git(['checkout', '-q', '--detach']);
    final trees = Worktrees(f.dir);
    expect(trees.fetch(), isNull);
    final made = trees.create('rex-6');
    expect(made.error, isNull);
    expect(made.worktree!.base, f.git(['rev-parse', 'HEAD']));
    expect(made.worktree!.from, isNull);
  });

  test("the Changes window doesn't count PRs merged on origin as the worker's changes", () async {
    final f = Fixture();
    f.merge('fix.txt');
    final trees = Worktrees(f.dir);
    await trees.fetch();
    final made = trees.create('rex-7').worktree!;
    final cwd = p.join(f.dir, made.path);
    f.commitIn(cwd, 'mine.txt');
    final target = ChangesTarget(name: 'Rex', cwd: cwd, rel: made.path, worktreeBase: made.base);
    final states = StreamController<ChangesState>();
    final changes = Changes(
      f.dir,
      'main',
      (_) => target,
      (_) => null,
      ChangesEvents(state: (s, _) => states.add(s), toast: (_, _) {}, refreshGitHub: () {}),
    );
    addTearDown(changes.stop);
    changes.watch('w1', 'c1');
    final state = await states.stream.first.timeout(const Duration(seconds: 20));
    expect(state.error, isNull);
    expect([for (final x in state.files) x.path], ['mine.txt']);
    expect(state.ahead, 1);
  });

  test('a worktree deleted with its branch comes back from origin when it was pushed', () async {
    final f = Fixture();
    final trees = Worktrees(f.dir);
    final made = trees.create('rex-9').worktree!;
    final abs = p.join(f.dir, made.path);
    final pushed = f.commitIn(abs, 'pushed.txt');
    f.run(abs, ['push', '-q', 'origin', made.branch]);
    expect(trees.branchState(made.branch), LostBranch.here);
    Directory(abs).deleteSync(recursive: true);
    f.git(['worktree', 'prune']);
    f.git(['branch', '-D', made.branch]);
    expect(trees.branchState(made.branch), LostBranch.origin);
    final ref = WorktreeRef(path: made.path, branch: made.branch, base: made.base);
    final back = await trees.restore(ref);
    expect(back.error, isNull);
    expect(back.from, LostBranch.origin);
    expect(f.run(abs, ['rev-parse', 'HEAD']), pushed);
    expect(f.run(abs, ['rev-parse', '--abbrev-ref', 'HEAD']), made.branch);
    // Checked out somewhere else already, it can't come back here: git says why.
    Directory(abs).deleteSync(recursive: true);
    f.git(['worktree', 'prune']);
    f.git(['checkout', '-q', made.branch]);
    final refused = await trees.restore(ref);
    expect(refused.error, matches(RegExp(r'already (checked out|used by worktree)')));
  });

  test('a worktree whose branch is gone everywhere is made again from where it started', () async {
    final f = Fixture();
    final trees = Worktrees(f.dir);
    final made = trees.create('rex-10').worktree!;
    final abs = p.join(f.dir, made.path);
    Directory(abs).deleteSync(recursive: true);
    f.git(['worktree', 'prune']);
    f.git(['branch', '-D', made.branch]);
    expect(trees.branchState(made.branch), LostBranch.gone);
    final back = await trees.restore(WorktreeRef(path: made.path, branch: made.branch, base: made.base));
    expect(back.from, LostBranch.gone);
    expect(f.run(abs, ['rev-parse', 'HEAD']), made.base);
  });
}
