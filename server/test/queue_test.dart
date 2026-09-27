// Port of tests/queue.test.ts.
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/queue.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A copy of [w] with another status (WorkerInfo is immutable; the TS test mutates it in place).
WorkerInfo withStatus(WorkerInfo w, WorkerStatus status) => WorkerInfo.fromJson({...w.toJson(), 'status': status.wire});

class FakeWorkers implements QueueWorkers {
  FakeWorkers(this.defaultProvider);

  @override
  final AgentProvider defaultProvider;
  final List<WorkerInfo> workers = [];

  @override
  List<WorkerInfo> list() => workers;

  @override
  bool deskOccupied(String deskId) => workers.any((w) => w.deskId == deskId);

  @override
  ({WorkerInfo? worker, String? error}) spawn(
    String deskId,
    String by,
    String prompt,
    bool worktree,
    WorkerKind kind,
    AgentProvider provider, [
    String? model,
  ]) {
    final worker = WorkerInfo(
      id: 'worker-${workers.length}',
      deskId: deskId,
      kind: kind,
      provider: provider,
      model: model,
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
    );
    workers.add(worker);
    return (worker: worker, error: null);
  }

  @override
  Future<({String? note, String? error})> kill(String id) async => (note: null, error: null);

  /// Sets worker [i]'s status, as the TS test does with `f.workers[i].status = ...`.
  WorkerInfo set(int i, WorkerStatus status) => workers[i] = withStatus(workers[i], status);
}

class Fixture {
  Fixture([AgentProvider defaultProvider = AgentProvider.claude])
    : dir = Directory.systemTemp.createTempSync('office-queue-').path,
      manager = FakeWorkers(defaultProvider);

  final String dir;
  final FakeWorkers manager;
  final List<TaskQueue> queues = [];
  int emptied = 0;

  List<WorkerInfo> get workers => manager.workers;

  TaskQueue open() {
    final queue = TaskQueue(
      dir,
      manager,
      false,
      QueueEvents(
        update: (_) {},
        toast: (_, _) {},
        claimIssue: (_) async => null,
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

Fixture fixture([AgentProvider defaultProvider = AgentProvider.claude]) {
  final f = Fixture(defaultProvider);
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

  test('queue rejects models unless they are valid OpenCode model ids', () {
    final f = fixture();
    final q = f.open();
    expect(
      q.add('Task', 'Tester', null, null, AgentProvider.claude, 'openai/gpt-5') ?? '',
      matches(RegExp('model|OpenCode', caseSensitive: false)),
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
}
