// Port of tests/leave-on-merge.test.ts.
import 'dart:io';

import 'package:agent_office_server/src/leave_on_merge.dart';
import 'package:agent_office_server/src/worktrees.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

WorkerInfo worker(String id, [WorkerStatus status = WorkerStatus.done, Map<String, dynamic> more = const {}]) =>
    WorkerInfo.fromJson({
      'id': id,
      'kind': 'agent',
      'deskId': 'desk-1',
      'name': id,
      'color': '#fff',
      'status': status.wire,
      'acked': false,
      'createdBy': 'test',
      'createdAt': 0,
      'cols': 80,
      'rows': 24,
      'viewers': <String>[],
      'worktree': {'path': '.agent-office/worktrees/$id', 'branch': 'office/$id', 'base': 'abc'},
      ...more,
    });

GhPull pull(int number, String state, String headRefName, [String? headRefOid]) => GhPull(
  number: number,
  title: 'PR $number',
  state: state,
  isDraft: false,
  url: '',
  author: '',
  labels: const [],
  reviewDecision: '',
  headRefName: headRefName,
  headRefOid: headRefOid,
  baseRefName: 'main',
  createdAt: '',
  updatedAt: '',
  additions: 0,
  deletions: 0,
  checks: GhChecks.none,
  body: '',
  closes: const [],
);

List<String> ids(List<WorkerInfo> workers, List<GhPull> pulls, [List<QueueTask> tasks = const []]) => [
  for (final l in landedWorkers(workers, pulls, tasks)) l.worker.id,
];

void main() {
  test('a worker at rest whose pull request merged goes, with the head of what merged', () {
    final head = 'a' * 40;
    final landed = landedWorkers([worker('mochi')], [pull(7, 'MERGED', 'office/mochi', head)], const []);
    expect(landed.length, 1);
    expect(landed[0].worker.id, 'mochi');
    expect(landed[0].pr, 7);
    expect(landed[0].head, head);
    for (final status in [WorkerStatus.idle, WorkerStatus.exited, WorkerStatus.offline]) {
      expect(ids([worker('mochi', status)], [pull(7, 'MERGED', 'office/mochi')]), ['mochi'], reason: '$status');
    }
  });

  test('a worker stays while its PR is open, a follow-up is open, or it has none', () {
    expect(ids([worker('a')], [pull(1, 'OPEN', 'office/a')]), isEmpty);
    expect(ids([worker('a')], [pull(1, 'MERGED', 'office/a'), pull(2, 'OPEN', 'office/a')]), isEmpty);
    expect(ids([worker('a')], [pull(1, 'CLOSED', 'office/a')]), isEmpty);
    expect(ids([worker('a')], [pull(1, 'MERGED', 'office/someone-else')]), isEmpty);
    // Opened from its desk but not on the list yet: open.
    expect(
      ids(
        [
          worker('a', WorkerStatus.done, {
            'pr': {'number': 9, 'url': ''},
          }),
        ],
        [pull(1, 'MERGED', 'office/a')],
      ),
      isEmpty,
    );
  });

  test('a worker stays while it works, waits on someone, opens a PR or has its terminal watched', () {
    final merged = [pull(1, 'MERGED', 'office/a')];
    for (final status in [WorkerStatus.starting, WorkerStatus.working, WorkerStatus.needsInput]) {
      expect(ids([worker('a', status)], merged), isEmpty, reason: '$status');
    }
    expect(
      ids([
        worker('a', WorkerStatus.done, {'prOpening': true}),
      ], merged),
      isEmpty,
    );
    expect(
      ids([
        worker('a', WorkerStatus.done, {
          'viewers': ['Cody'],
        }),
      ], merged),
      isEmpty,
    );
  });

  test('shells, board agents and the meeting table never go by pull request', () {
    final merged = [pull(1, 'MERGED', 'office/a')];
    expect(
      ids([
        worker('a', WorkerStatus.done, {'kind': 'shell'}),
      ], merged),
      isEmpty,
    );
    expect(
      ids([
        worker('a', WorkerStatus.done, {'deskId': 'station-pulls'}),
      ], merged),
      isEmpty,
    );
    expect(
      ids([
        worker('a', WorkerStatus.done, {'meeting': 'm1'}),
      ], merged),
      isEmpty,
    );
  });

  test("a queue task's merged PR counts after it drops off GitHub's list", () {
    final task = QueueTask(
      id: 't',
      title: 't',
      prompt: 't',
      addedBy: 'x',
      addedAt: 0,
      status: TaskStatus.done,
      workerId: 'a',
      pr: const QueueTaskPr(number: 4, url: '', state: 'MERGED', title: 't'),
    );
    final w = WorkerInfo.fromJson({...worker('a').toJson()}..remove('worktree'));
    final landed = landedWorkers([w], const [], [task]);
    expect([for (final l in landed) (l.worker.id, l.pr, l.head)], [('a', 4, null)]);
  });

  test('the setting is off until someone turns it on, and keeps across restarts', () {
    final dir = Directory.systemTemp.createTempSync('office-leave-').path;
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    final told = <bool>[];
    final a = LeaveOnMerge(dir, (s) => told.add(s.on));
    expect(a.state().toJson(), {'on': false});
    a.set(true, 'Cody');
    expect(told, [true]);
    final b = LeaveOnMerge(dir, (_) {});
    expect(b.on, isTrue);
    expect(b.state().by, 'Cody');
  });

  test("commits in the merged PR aren't work a worktree would lose, even with the branch gone from GitHub", () async {
    final dir = Directory.systemTemp.createTempSync('office-landed-').path;
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    String git(List<String> args) {
      final r = Process.runSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', ...args], workingDirectory: dir);
      if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
      return '${r.stdout}'.trim();
    }

    git(['init', '-q', '-b', 'main']);
    File(p.join(dir, 'a.txt')).writeAsStringSync('a');
    git(['add', '.']);
    git(['commit', '-qm', 'init']);
    final base = git(['rev-parse', 'HEAD']);
    // Two commits on the worker's branch, no remote at all (as if GitHub deleted it and a fetch pruned it).
    git(['checkout', '-qb', 'office/mochi']);
    for (final n in [1, 2]) {
      File(p.join(dir, 'f$n.txt')).writeAsStringSync('$n');
      git(['add', '.']);
      git(['commit', '-qm', 'c$n']);
    }
    final merged = git(['rev-parse', 'HEAD']);
    git(['checkout', '-q', 'main']);
    final trees = Worktrees(dir);
    final wt = WorktreeRef(branch: 'office/mochi', base: base);
    expect((await trees.inspect(wt)).unpushed, 2);
    expect((await trees.inspect(wt, merged)).unpushed, 0);
    // A commit GitHub has and this checkout doesn't: it can't vouch for anything.
    expect((await trees.inspect(wt, 'b' * 40)).unpushed, 2);
    expect((await trees.inspect(wt, '--all')).unpushed, 2);
    // Work after what merged still counts.
    git(['checkout', '-q', 'office/mochi']);
    File(p.join(dir, 'f3.txt')).writeAsStringSync('3');
    git(['add', '.']);
    git(['commit', '-qm', 'c3']);
    git(['checkout', '-q', 'main']);
    expect((await trees.inspect(wt, merged)).unpushed, 1);
  });
}
