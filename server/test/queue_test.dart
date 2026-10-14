import 'dart:async';
// Port of tests/queue.test.ts.
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/agents.dart' show validateWorkerEffort;
import 'package:agent_office_server/src/queue.dart';
import 'package:agent_office_server/src/worker_pr.dart' show RepoSource;
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A copy of [w] with another status (WorkerInfo is immutable; the TS test mutates it in place).
WorkerInfo withStatus(WorkerInfo w, WorkerStatus status) => WorkerInfo.fromJson({...w.toJson(), 'status': status.wire});

class FakeWorkers implements QueueWorkers {
  FakeWorkers(this.defaultProvider, [this.officeDefault]);

  @override
  final AgentProvider defaultProvider;
  @override
  final AgentChoice? officeDefault;
  final List<WorkerInfo> workers = [];
  final List<String?> owners = [];
  int hired = 0;

  @override
  List<WorkerInfo> list() => workers;

  @override
  bool deskOccupied(String deskId) => workers.any((w) => w.deskId == deskId);

  /// How far the back office is built out.
  int built = 0;
  @override
  int wing() => built;

  @override
  ({WorkerInfo? worker, String? error}) spawn(
    String deskId,
    String by,
    String prompt,
    bool worktree,
    WorkerKind kind,
    AgentProvider provider, [
    String? model,
    AgentEffort? effort,
    ({String id, WorkerWorktree? worktree})? meeting,
    List<RepoSource> repos = const [],
    String? owner,
  ]) {
    owners.add(owner);
    final id = 'worker-${hired++}';
    final worker = WorkerInfo(
      id: id,
      deskId: deskId,
      kind: kind,
      provider: provider,
      model: model,
      effort: effort,
      prompt: prompt,
      name: 'Test',
      color: '#ffffff',
      status: WorkerStatus.working,
      acked: false,
      createdBy: by,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      cols: 80,
      rows: 24,
      viewers: const [],
      worktree: worktree
          ? WorkerWorktree(path: '.agent-office/worktrees/$id', branch: 'office/$id', base: 'abc')
          : null,
    );
    workers.add(worker);
    return (worker: worker, error: null);
  }

  /// What [fetchBase] hands the queue: a fetch in flight, or null for nothing to wait for.
  Future<void>? fetching;
  int fetches = 0;

  @override
  Future<void>? fetchBase() {
    fetches++;
    return fetching;
  }

  @override
  Future<({String? note, String? error})> kill(String id) async {
    // Gone from the desks right away, the way the real one does it (before its worktree is dealt with).
    workers.removeWhere((w) => w.id == id);
    return (note: null, error: null);
  }

  /// Sets worker [i]'s status, as the TS test does with `f.workers[i].status = ...`.
  WorkerInfo set(int i, WorkerStatus status) => workers[i] = withStatus(workers[i], status);
}

class Fixture {
  Fixture([AgentProvider defaultProvider = AgentProvider.claude, AgentChoice? officeDefault])
    : dir = Directory.systemTemp.createTempSync('office-queue-').path,
      manager = FakeWorkers(defaultProvider, officeDefault);

  final String dir;
  final FakeWorkers manager;
  final List<TaskQueue> queues = [];
  int emptied = 0;

  List<WorkerInfo> get workers => manager.workers;

  TaskQueue open({num Function()? room, bool worktree = false, String Function()? worktreeNote}) {
    final queue = TaskQueue(
      dir,
      manager,
      worktree,
      QueueEvents(
        room: room,
        worktreeNote: worktreeNote,
        update: (_) {},
        toast: (_, _) {},
        claimIssue: (_, _) async => null,
        refreshGitHub: () {},
        hiringPaused: () => null,
        emptied: () => emptied++,
      ),
    );
    queues.add(queue);
    return queue;
  }

  void close() {
    for (final q in queues) {
      q.shutdown();
    }
    Directory(dir).deleteSync(recursive: true);
  }
}

Fixture fixture([AgentProvider defaultProvider = AgentProvider.claude, AgentChoice? officeDefault]) {
  final f = Fixture(defaultProvider, officeDefault);
  addTearDown(f.close);
  return f;
}

void main() {
  test('queue seats the selected provider and preserves it through completion and retry', () {
    final f = fixture();
    final q = f.open();
    expect(q.add('Fix login', 'Tester', null, null, AgentProvider.opencode), isNull);
    expect(f.workers[0].provider, AgentProvider.opencode);
    q.onWorker(f.manager.set(0, WorkerStatus.needsInput));
    expect(q.state().tasks[0].status, TaskStatus.running);
    q.onWorker(f.manager.set(0, WorkerStatus.done));
    expect(q.state().tasks[0].outcome, TaskOutcome.done);
    q.retry(q.state().tasks[0].id);
    expect(f.workers[1].provider, AgentProvider.opencode);
  });

  test('the queue seats its workers at the back office once it is built, before any bean bag', () {
    for (final built in [0, 1]) {
      final f = fixture();
      f.manager.built = built;
      // Every desk in the room taken, by hand.
      for (final d in desks) {
        f.manager.workers.add(
          WorkerInfo(
            id: 'hand-${d.id}',
            kind: WorkerKind.agent,
            deskId: d.id,
            name: 'Hand',
            color: '#000000',
            status: WorkerStatus.idle,
            acked: true,
            createdBy: 'Ada',
            createdAt: 0,
            cols: 80,
            rows: 24,
            viewers: const [],
          ),
        );
      }
      final q = f.open();
      expect(q.add('Fix login', 'Tester', null, null, AgentProvider.claude), isNull);
      expect(f.workers.last.deskId, built == 0 ? beanbags.first.id : wingDesks.first.id);
    }
  });

  test("a task runs on the sign-ins of whoever queued it, after a restart and a retry too", () {
    final f = fixture();
    final q = f.open();
    q.setLimit(0);
    q.add('Fix login', 'Ada', null, null, AgentProvider.claude, null, null, 'acct01');
    q.add('Fix logout', 'Guest', null, null, AgentProvider.claude);
    expect(q.state().tasks.map((t) => t.owner), ['acct01', null]);
    q.shutdown();
    final restored = f.open();
    restored.setLimit(2);
    expect(f.manager.owners, ['acct01', null]);
    restored.onWorker(f.manager.set(0, WorkerStatus.done));
    restored.retry(restored.state().tasks.firstWhere((t) => t.owner == 'acct01').id);
    expect(f.manager.owners.last, 'acct01');
  });
  test('queued provider survives restart even when the configured default differs', () {
    final f = fixture();
    final q = f.open();
    q.setLimit(0);
    q.add('Fix login', 'Tester', null, null, AgentProvider.opencode);
    q.shutdown();
    final restored = f.open();
    restored.setLimit(1);
    expect(f.workers[0].provider, AgentProvider.opencode);
  });

  test('new and legacy tasks without a provider use the configured agent', () {
    final f = fixture(AgentProvider.custom);
    File(p.join(f.dir, 'queue.json')).writeAsStringSync(
      jsonEncode({
        'maxWorkers': 0,
        'tasks': [
          {'id': 'legacy', 'title': 'Legacy', 'prompt': 'Legacy task', 'status': 'queued'},
        ],
      }),
    );
    final q = f.open();
    q.add('New task', 'Tester');
    q.setLimit(2);
    expect([for (final w in f.workers) w.provider], [AgentProvider.custom, AgentProvider.custom]);
  });

  test('invalid or unavailable providers are rejected before a task is queued', () {
    final f = fixture();
    final q = f.open();
    // The TS case also tries a provider that isn't one ('bad'); an AgentProvider can't be that in Dart.
    expect(
      q.add('Task', 'Tester', null, null, AgentProvider.custom) ?? '',
      matches(RegExp('provider', caseSensitive: false)),
    );
    expect(q.state().tasks.length, 0);
  });

  test('queue preserves the selected OpenCode model through seating, retry, and restart', () {
    final f = fixture();
    final q = f.open();
    expect(q.add('Fix login', 'Tester', null, null, AgentProvider.opencode, 'openai/gpt-5/nested'), isNull);
    expect(f.workers[0].model, 'openai/gpt-5/nested');
    expect(q.state().tasks[0].model, 'openai/gpt-5/nested');
    q.onWorker(f.manager.set(0, WorkerStatus.done));
    q.retry(q.state().tasks[0].id);
    expect(f.workers[1].model, 'openai/gpt-5/nested');

    q.setLimit(0);
    q.add('Queued', 'Tester', null, null, AgentProvider.opencode, 'anthropic/claude-sonnet-4');
    q.shutdown();
    final restored = f.open();
    restored.setLimit(2);
    expect(f.workers[2].model, 'anthropic/claude-sonnet-4');
  });

  test('queue rejects models unless they are valid Claude aliases or OpenCode model ids', () {
    final f = fixture();
    final q = f.open();
    expect(
      q.add('Task', 'Tester', null, null, AgentProvider.claude, 'openai/gpt-5') ?? '',
      matches(RegExp('model', caseSensitive: false)),
    );
    expect(
      q.add('Task', 'Tester', null, null, AgentProvider.opencode, 'gpt-5') ?? '',
      matches(RegExp('model|format|provider', caseSensitive: false)),
    );
    expect(
      q.add('Task', 'Tester', null, null, AgentProvider.opencode, 'openai/gpt 5') ?? '',
      matches(RegExp('model|format|whitespace', caseSensitive: false)),
    );
    expect(q.state().tasks.length, 0);
  });

  test('the queue says it emptied once, when its last task gets done', () {
    final f = fixture();
    final q = f.open();
    q.add('First', 'Tester');
    q.add('Second', 'Tester');
    q.onWorker(f.manager.set(0, WorkerStatus.done));
    expect(f.emptied, 0, reason: 'the second task is still running');
    q.onWorker(f.manager.set(1, WorkerStatus.done));
    expect(f.emptied, 1);
    q.onWorker(withStatus(f.workers[1], WorkerStatus.idle));
    q.onWorker(f.workers[1]);
    expect(f.emptied, 1, reason: 'finished tasks never empty it again');
  });

  test('the queue does not celebrate a task that stopped short, or one taken off it', () {
    final f = fixture();
    final q = f.open();
    q.add('Crashes', 'Tester');
    q.onWorker(f.manager.set(0, WorkerStatus.exited));
    expect(q.state().tasks[0].outcome, TaskOutcome.exited);
    q.setLimit(0);
    q.add('Never starts', 'Tester');
    q.remove(q.state().tasks[1].id);
    expect(f.emptied, 0);
  });

  test('queue rejects a reasoning effort its provider takes none of, or nobody knows', () {
    final f = fixture();
    final q = f.open();
    // Cursor's effort is part of its model id: it takes none of its own.
    expect(
      q.add('Task', 'Tester', null, null, AgentProvider.cursor, null, AgentEffort.high) ?? '',
      matches(RegExp('effort', caseSensitive: false)),
    );
    // An unknown level ('overdrive') can't be an AgentEffort in Dart; the validator still says so.
    expect(validateEffortText('overdrive'), matches(RegExp('effort', caseSensitive: false)));
    expect(q.state().tasks.length, 0);
  });

  test('queue preserves a Claude model and effort through seating, retry, and restart', () {
    final f = fixture();
    final q = f.open();
    expect(q.add('Fix login', 'Tester', null, null, AgentProvider.claude, 'haiku', AgentEffort.low), isNull);
    expect(f.workers[0].model, 'haiku');
    expect(f.workers[0].effort, AgentEffort.low);
    expect(q.state().tasks[0].model, 'haiku');
    expect(q.state().tasks[0].effort, AgentEffort.low);
    q.onWorker(f.manager.set(0, WorkerStatus.done));
    q.retry(q.state().tasks[0].id);
    expect(f.workers[1].model, 'haiku');
    expect(f.workers[1].effort, AgentEffort.low);

    q.setLimit(0);
    q.add('Queued', 'Tester', null, null, AgentProvider.claude, 'opus', AgentEffort.max);
    q.shutdown();
    final restored = f.open();
    restored.setLimit(2);
    expect(f.workers[2].model, 'opus');
    expect(f.workers[2].effort, AgentEffort.max);
  });

  test('queue takes Fable and restores it from queue.json', () {
    final f = fixture();
    final q = f.open();
    q.setLimit(0);
    expect(q.add('Big task', 'Tester', null, null, AgentProvider.claude, 'fable', AgentEffort.xhigh), isNull);
    q.shutdown();
    final saved = jsonDecode(File(p.join(f.dir, 'queue.json')).readAsStringSync());
    expect(saved['tasks'][0]['model'], 'fable');
    final restored = f.open();
    expect(restored.state().tasks[0].model, 'fable');
    restored.setLimit(1);
    expect(f.workers[0].model, 'fable');
    expect(f.workers[0].effort, AgentEffort.xhigh);
  });

  test("a board agent at work does not hold one of the queue's slots", () {
    final f = fixture();
    f.workers.add(agent('issues-agent', 'station-issues', WorkerStatus.working));
    final q = f.open();
    q.setLimit(1);
    q.add('Fix login', 'Tester');
    expect(q.state().tasks[0].status, TaskStatus.running);
    // Its seat is a desk, never the kiosk.
    expect(f.workers[1].deskId, startsWith('desk-'));
  });

  test("workers hired by hand, or left at their prompt after a restart, do not hold the queue's slots", () {
    final f = fixture();
    // A room full of workers from before the restart, back at their prompts, and a couple at work.
    for (var i = 1; i <= 6; i++) {
      f.workers.add(agent('resumed-$i', 'desk-$i', i <= 4 ? WorkerStatus.idle : WorkerStatus.working));
    }
    final q = f.open();
    q.setLimit(2);
    q.add('First', 'Tester');
    q.add('Second', 'Tester');
    q.add('Third', 'Tester');
    // Only the queue's own tasks count against its limit.
    expect([for (final t in q.state().tasks) t.status], [TaskStatus.running, TaskStatus.running, TaskStatus.queued]);
    expect([for (final w in f.workers.skip(6)) w.deskId], ['desk-7', 'desk-8']);
    // One of its tasks finishes: the third takes the slot, whatever the other workers are up to.
    q.onWorker(f.manager.set(6, WorkerStatus.done));
    expect([for (final t in q.state().tasks) t.status], [TaskStatus.done, TaskStatus.running, TaskStatus.running]);
  });

  test('an office at its worker limit holds the queue, and a finished queue worker makes room', () async {
    final f = fixture();
    var limit = 1;
    final q = f.open(room: () => limit - f.workers.length);
    q.add('First', 'Tester');
    q.add('Second', 'Tester');
    expect([for (final t in q.state().tasks) t.status], [TaskStatus.running, TaskStatus.queued]);
    expect(f.workers.length, 1);
    // The first finishes: its worker goes home to make room, and the second task gets the seat.
    q.onWorker(f.manager.set(0, WorkerStatus.done));
    expect([for (final t in q.state().tasks) t.status], [TaskStatus.done, TaskStatus.running]);
    expect([for (final w in f.workers) w.id], ['worker-1']);
    // The limit lowered past who's there: nobody is sent home and nothing fails, the queue just waits.
    q.add('Third', 'Tester');
    limit = 0;
    q.onWorker(f.manager.set(0, WorkerStatus.done));
    expect(
      [for (final t in q.state().tasks) (t.status, t.outcome)],
      [(TaskStatus.done, TaskOutcome.done), (TaskStatus.done, TaskOutcome.done), (TaskStatus.queued, null)],
    );
    expect(f.workers.length, 1);
    // Room again: it carries on.
    limit = 2;
    q.pump();
    expect(q.state().tasks[2].status, TaskStatus.running);
  });

  // From tests/prompts.test.ts: the office default worker, and the worktree note.
  test('a task nobody picked a worker for runs on the office default; one that did keeps its own', () {
    final f = fixture(
      AgentProvider.claude,
      const AgentChoice(provider: AgentProvider.claude, model: 'sonnet', effort: AgentEffort.low),
    );
    final q = f.open();
    expect(q.add('Fix the dog', 'Queue agent'), isNull);
    expect(
      [f.workers[0].provider, f.workers[0].model, f.workers[0].effort],
      [AgentProvider.claude, 'sonnet', AgentEffort.low],
    );
    expect(q.add('Fix the cat', 'Ada', null, null, AgentProvider.claude, 'haiku'), isNull);
    expect([f.workers[1].provider, f.workers[1].model, f.workers[1].effort], [AgentProvider.claude, 'haiku', null]);
    // Without one set, it's the office's --agent on its own model.
    final plain = fixture();
    plain.open().add('Fix it', 'Ada');
    expect([plain.workers[0].provider, plain.workers[0].model], [AgentProvider.claude, null]);
  });

  test('the worktree note the queue adds can be rewritten, or left off', () {
    final standard = fixture();
    standard.open(worktree: true).add('Fix it', 'Ada');
    expect(standard.workers[0].prompt, 'Fix it\n\n${prompts['queue.worktree']!.text}');
    final rewritten = fixture();
    rewritten.open(worktree: true, worktreeNote: () => 'Push to your branch.').add('Fix it', 'Ada');
    expect(rewritten.workers[0].prompt, 'Fix it\n\nPush to your branch.');
    final none = fixture();
    none.open(worktree: true, worktreeNote: () => '').add('Fix it', 'Ada');
    expect(none.workers[0].prompt, 'Fix it');
  });

  test('a worktree task waits for the fetch of what its worktree starts from, then sits down', () async {
    final dir = Directory.systemTemp.createTempSync('office-queue-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final manager = FakeWorkers(AgentProvider.claude);
    final fetched = Completer<void>();
    manager.fetching = fetched.future;
    final q = TaskQueue(
      dir.path,
      manager,
      true,
      QueueEvents(
        update: (_) {},
        toast: (_, _) {},
        claimIssue: (_, _) async => null,
        refreshGitHub: () {},
        hiringPaused: () => null,
        emptied: () {},
      ),
    );
    addTearDown(q.shutdown);
    q.add('Fix login', 'Tester');
    q.add('Fix logout', 'Tester');
    expect(manager.workers, isEmpty);
    expect(q.state().tasks[0].status, TaskStatus.queued);
    q.pump();
    expect(manager.workers, isEmpty);
    manager.fetching = null;
    fetched.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    // One fetch for the pair of them.
    expect(manager.workers.length, 2);
    expect([for (final t in q.state().tasks) t.status], [TaskStatus.running, TaskStatus.running]);
  });

  test("a queue that has nowhere to seat anyone doesn't fetch", () {
    final dir = Directory.systemTemp.createTempSync('office-queue-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final manager = FakeWorkers(AgentProvider.claude)..fetching = Completer<void>().future;
    final q = TaskQueue(
      dir.path,
      manager,
      true,
      QueueEvents(
        update: (_) {},
        toast: (_, _) {},
        claimIssue: (_, _) async => null,
        refreshGitHub: () {},
        hiringPaused: () => null,
        emptied: () {},
        room: () => 0,
      ),
    );
    addTearDown(q.shutdown);
    q.add('Fix login', 'Tester');
    expect(manager.fetches, 0);
  });

  test("a queue worker that switches to a branch of its own takes its task's branch along, so the PR from there is "
      'linked', () {
    final f = fixture();
    final q = f.open(worktree: true);
    expect(q.add('Fix login', 'Tester'), isNull);
    expect(q.state().tasks[0].branch, 'office/worker-0');
    q.onWorker(f.manager.set(0, WorkerStatus.done));
    expect(q.state().tasks[0].outcome, TaskOutcome.done);
    // The office noticed it had run `git checkout -b fix-login` (see WorkerManager.syncBranches).
    final w = f.workers[0];
    f.workers[0] = WorkerInfo.fromJson({
      ...w.toJson(),
      'worktree': {...w.worktree!.toJson(), 'branch': 'fix-login', 'made': 'office/worker-0'},
    });
    q.onWorker(f.workers[0]);
    expect(q.state().tasks[0].branch, 'fix-login');
    q.onPulls([
      GhPull.fromJson({
        'number': 242,
        'title': 'Fix login',
        'state': 'OPEN',
        'isDraft': false,
        'url': 'https://github.com/o/r/pull/242',
        'author': '',
        'labels': <String>[],
        'reviewDecision': '',
        'headRefName': 'fix-login',
        'baseRefName': 'main',
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': '',
        'additions': 0,
        'deletions': 0,
        'checks': 'none',
        'body': '',
        'closes': <int>[],
      }),
    ]);
    expect(q.state().tasks[0].pr?.number, 242);
  });
}

String? validateEffortText(String effort) => validateWorkerEffort(WorkerKind.agent, AgentProvider.claude, effort);

WorkerInfo agent(String id, String deskId, WorkerStatus status) => WorkerInfo(
  id: id,
  deskId: deskId,
  kind: WorkerKind.agent,
  provider: AgentProvider.claude,
  name: id,
  color: '#ffffff',
  status: status,
  acked: true,
  createdBy: 'Ada',
  createdAt: DateTime.now().millisecondsSinceEpoch,
  cols: 80,
  rows: 24,
  viewers: const [],
);
