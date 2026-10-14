// A worktree worker that makes a branch of its own is followed there (upstream #172): the PR badge,
// O at the desk and sending it home go by the branch it's on, and only branches it made are deleted.
@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/github.dart' show ghCommand;
import 'package:agent_office_server/src/worktrees.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workers_test.dart' show Fixture, Invocation, isolatedEnv, manager, spawned, waitFor;

String git(String cwd, List<String> args, [Map<String, String>? env]) {
  final r = Process.runSync(
    'git',
    ['-c', 'user.email=t@t', '-c', 'user.name=t', ...args],
    workingDirectory: cwd,
    environment: env,
  );
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return '${r.stdout}'.trim();
}

void initRepo(String dir) {
  git(dir, ['init', '-q', '-b', 'main']);
  File(p.join(dir, 'a.txt')).writeAsStringSync('a');
  git(dir, ['add', 'a.txt']);
  git(dir, ['commit', '-qm', 'init']);
}

/// A branch that was there long before any worker (its reflog says it was made in 2001).
void oldBranch(String dir, String name) => git(dir, ['branch', name], {'GIT_COMMITTER_DATE': '@1000000000 +0000'});

List<Invocation> launches(Fixture f) =>
    f.read().where((r) => r.kind == 'claude' && !r.args.contains('--output-format') && r.stdin == null).toList();

void commit(String cwd, String file, String message) {
  File(p.join(cwd, file)).writeAsStringSync(file);
  git(cwd, ['add', file]);
  git(cwd, ['commit', '-qm', message]);
}

void main() {
  late Fixture f;
  late Map<String, String> env;
  setUp(() {
    f = Fixture();
    env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
    initRepo(f.root);
  });
  tearDown(() async {
    ghCommand = 'gh';
    await f.close();
  });

  test('a worktree worker that makes its own branch is followed there: O finds the PR it opened, and sending it '
      'home tidies both branches', () async {
    // GitHub has one open pull request, from the branch the worker is about to make.
    final fakeGh = p.join(f.bin, 'gh');
    File(fakeGh).writeAsStringSync(
      '#!/bin/sh\ncase "\$*" in *"--head fix-x "*) echo \'[{"number":242,"url":"https://github.com/o/r/pull/242"}]\';; '
      "*) echo '[]';; esac\n",
    );
    Process.runSync('chmod', ['700', fakeGh]);
    ghCommand = fakeGh;
    final updates = <WorkerInfo>[];
    final workers = manager(f, f.claude, updates, env);
    addTearDown(workers.shutdown);
    final worker = spawned(workers.spawn('desk-1', 'test', 'fix x on a new branch and open a PR', true));
    final office = worker.worktree!.branch;
    expect(office, startsWith('office/'));
    final token = (await waitFor(() => launches(f), (x) => x.isNotEmpty)).first.hookToken!;
    void hook(String event, [Map<String, Object?> extra = const {}]) =>
        expect(workers.handleHook(worker.id, token, event, {'session_id': 'own-branch', ...extra}), isTrue);
    hook('SessionStart');
    hook('UserPromptSubmit', {'prompt': 'fix x on a new branch and open a PR'});
    // What the task (or the repo's CLAUDE.md) told it to do: a branch of its own, a commit, a PR from there.
    final cwd = p.join(f.root, worker.worktree!.path);
    git(cwd, ['checkout', '-qb', 'fix-x']);
    commit(cwd, 'x.txt', 'fix x');
    hook('Stop');
    final info = await waitFor(() => workers.get(worker.id)!, (w) => w.worktree?.branch == 'fix-x');
    expect(info.worktree!.made, office);
    expect(updates.last.worktree?.branch, 'fix-x');
    // Saved, for a restarted office and for `agent-office prune`.
    final saved = jsonDecode(File(p.join(f.data, 'workers.json')).readAsStringSync()) as List;
    final mine = saved.firstWhere((w) => w['id'] == worker.id) as Map;
    expect(mine['worktree'], info.worktree!.toJson());
    // O at the desk: the PR it opened, not "has no commits on office/… yet".
    final pr = await workers.openPr(worker.id, 'Cody');
    expect(pr.error, isNull);
    final one = pr.prs.single;
    expect(
      (one.repo, one.number, one.url, one.existed, one.dirty),
      (null, 242, 'https://github.com/o/r/pull/242', true, false),
    );
    expect(workers.get(worker.id)?.pr?.number, 242);
    // Sent home: the worktree goes, with its branch and the office's (which holds nothing fix-x lacks).
    final home = await workers.kill(worker.id, WorktreeCleanup.all);
    expect(home.error, isNull);
    expect(home.note, "Deleted ${worker.name}'s worktree and branch fix-x");
    expect(git(f.root, ['branch', '--list', 'fix-x', office]), '');
    expect(Directory(cwd).existsSync(), isFalse);
    // One that checked out a branch from before it was hired leaves that branch be.
    oldBranch(f.root, 'release');
    final other = spawned(workers.spawn('desk-2', 'test', 'look at the release branch', true));
    git(p.join(f.root, other.worktree!.path), ['checkout', '-q', 'release']);
    final left = await workers.kill(other.id, WorktreeCleanup.all);
    expect(left.note, "Deleted ${other.name}'s worktree and branch ${other.worktree!.branch}");
    expect(
      git(f.root, ['branch', '--list', '--format=%(refname:short)', 'release', other.worktree!.branch]),
      'release',
    );
  });

  test("the office's branch keeps a worker's commits once it has moved on: the dialog warns, and sending it home "
      'never deletes them', () async {
    oldBranch(f.root, 'release');
    final workers = manager(f, f.claude, [], env);
    addTearDown(workers.shutdown);
    // A worker that commits on the office's branch, then goes to another one.
    ({WorkerInfo w, String cwd, String office}) hire(String desk, List<String> checkout) {
      final w = spawned(workers.spawn(desk, 'test', 'commit, then switch branches', true));
      final cwd = p.join(f.root, w.worktree!.path);
      commit(cwd, '$desk.txt', 'work at $desk');
      git(cwd, ['checkout', '-q', ...checkout]);
      return (w: w, cwd: cwd, office: w.worktree!.branch);
    }

    String tip(String branch) => git(f.root, ['log', '-1', '--format=%s', branch]);
    // Onto release, which was there before it: the commit is only on the office's branch.
    final a = hire('desk-1', ['release']);
    final state = (await workers.inspectWorktree(a.w.id))!;
    expect((state.exists, state.dirty, state.ahead, state.unpushed, state.error), (true, 0, 1, 1, null));
    expect(workers.get(a.w.id)?.worktree?.made, a.office);
    // Deleting the worktree and branch anyway: release isn't the office's, and the office's has the commit.
    final sent = await workers.kill(a.w.id, WorktreeCleanup.all);
    expect(sent.error, isNull);
    expect(sent.note, "Deleted ${a.w.name}'s worktree and kept branch ${a.office} — it has 1 unpushed commit");
    expect(Directory(a.cwd).existsSync(), isFalse);
    expect(tip(a.office), 'work at desk-1');
    expect(tip('release'), 'init');
    // Sent home with no choice (the queue recycling its desk, leave-on-merge): nothing goes.
    final b = hire('desk-2', ['release']);
    expect(
      (await workers.kill(b.w.id)).note,
      "Kept ${b.w.name}'s worktree and branch release — it has 1 unpushed commit",
    );
    expect(Directory(b.cwd).existsSync(), isTrue);
    expect(tip(b.office), 'work at desk-2');
    // A branch of its own, cut from main without that commit: it goes, the office's stays.
    final c = hire('desk-3', ['-b', 'fix-z', 'main']);
    final own = await workers.kill(c.w.id, WorktreeCleanup.all);
    expect(
      own.note,
      "Deleted ${c.w.name}'s worktree and branch fix-z, and kept branch ${c.office} — it has 1 unpushed commit",
    );
    expect(git(f.root, ['branch', '--list', 'fix-z']), '');
    expect(tip(c.office), 'work at desk-3');
  });

  test(
    "a worker that renames the office's branch goes home with it; one that deletes it leaves the branch it's on",
    () async {
      final workers = manager(f, f.claude, [], env);
      addTearDown(workers.shutdown);
      ({WorkerInfo w, String cwd, String office}) hire(String desk) {
        final w = spawned(workers.spawn(desk, 'test', 'fix x and name the branch after it', true));
        return (w: w, cwd: p.join(f.root, w.worktree!.path), office: w.worktree!.branch);
      }

      final a = hire('desk-1');
      final token = (await waitFor(() => launches(f), (x) => x.isNotEmpty)).first.hookToken!;
      void hook(String event, [Map<String, Object?> extra = const {}]) =>
          expect(workers.handleHook(a.w.id, token, event, {'session_id': 'renamed', ...extra}), isTrue);
      hook('SessionStart');
      hook('UserPromptSubmit', {'prompt': 'fix x and name the branch after it'});
      commit(a.cwd, 'x.txt', 'fix x');
      git(a.cwd, ['branch', '-m', 'fix-x']);
      hook('Stop');
      // Followed there, with nothing to remember: office/… is gone, fix-x is it.
      final info = await waitFor(() => workers.get(a.w.id)!, (w) => w.worktree?.branch == 'fix-x');
      expect(info.worktree!.made, isNull);
      final sent = await workers.kill(a.w.id, WorktreeCleanup.all);
      expect(sent.error, isNull);
      expect(sent.note, "Deleted ${a.w.name}'s worktree and branch fix-x");
      expect(git(f.root, ['branch', '--list', 'fix-x', a.office]), '');
      expect(Directory(a.cwd).existsSync(), isFalse);
      // Renamed with nothing unpushed (its PR merged, say) and sent home before it came to rest: all of it goes.
      final b = hire('desk-2');
      git(b.cwd, ['branch', '-m', 'fix-y']);
      final bHome = await workers.kill(b.w.id);
      expect((bHome.note, bHome.error), ("Deleted ${b.w.name}'s worktree and branch fix-y", null));
      expect(git(f.root, ['branch', '--list', 'fix-y', b.office]), '');
      // The office's branch deleted instead: git can't say whether the one it's on is its own, so it stays.
      final c = hire('desk-3');
      git(c.cwd, ['checkout', '-qb', 'fix-w']);
      git(c.cwd, ['branch', '-D', c.office]);
      final cHome = await workers.kill(c.w.id, WorktreeCleanup.all);
      expect((cHome.note, cHome.error), ("Deleted ${c.w.name}'s worktree and kept branch fix-w", null));
      expect(git(f.root, ['branch', '--list', '--format=%(refname:short)', 'fix-w', c.office]), 'fix-w');
      expect(Directory(c.cwd).existsSync(), isFalse);
    },
  );

  test("only a branch the worker made is its own to delete, and the office's stays when it has commits that one "
      "doesn't", () async {
    final dir = f.root;
    oldBranch(dir, 'release');
    final trees = Worktrees(dir);
    final made = trees.create('mochi-1234').worktree!;
    final cwd = p.join(dir, made.path);
    // A commit on the office's branch, then a fresh branch from main that doesn't have it.
    commit(cwd, 'o.txt', 'on the office branch');
    git(cwd, ['checkout', '-qb', 'fix-y', 'main']);
    final ref = WorktreeRef(path: made.path, branch: made.branch, base: made.base);
    expect(await trees.branchOf(ref), 'fix-y');
    expect(await trees.madeSince('fix-y', made.branch), isTrue);
    expect(await trees.madeSince('release', made.branch), isFalse);
    expect(await trees.madeSince('main', made.branch), isFalse);
    expect(
      await trees.remove(
        WorktreeRef(path: made.path, branch: 'fix-y', base: made.base, made: made.branch),
        WorktreeCleanup.all,
      ),
      isNull,
    );
    expect(git(dir, ['branch', '--list', 'fix-y']), '');
    expect(git(dir, ['branch', '--list', made.branch]).replaceFirst(RegExp(r'^\*?\s+'), ''), made.branch);
  });
}
