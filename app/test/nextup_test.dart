import 'package:agent_office/nextup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

WorkerInfo worker(String id, WorkerStatus status, {int? waitingSince, bool acked = false, int createdAt = 0}) =>
    WorkerInfo(
      id: id,
      kind: WorkerKind.agent,
      deskId: 'desk-$id',
      name: id,
      color: '#fff',
      status: status,
      acked: acked,
      waitingSince: waitingSince,
      createdBy: 'test',
      createdAt: createdAt,
      cols: 80,
      rows: 24,
      viewers: const [],
    );

List<String?> ids(Iterable<WorkerInfo?> ws) => [for (final w in ws) w?.id];

void main() {
  test('three workers waiting: N three times visits each of them, the ones that need you first and oldest first, then starts over', () {
    final workers = {
      for (final w in [
        worker('b', WorkerStatus.needsInput, waitingSince: 200),
        worker('busy', WorkerStatus.working),
        worker('a', WorkerStatus.done, waitingSince: 100),
        worker('c', WorkerStatus.needsInput, waitingSince: 300),
        worker('seen', WorkerStatus.done, waitingSince: 50, acked: true),
      ])
        w.id: w,
    };
    expect(ids(waitingInOrder(workers.values)), ['b', 'c', 'a']);
    final n = NextUp();
    expect(ids([for (var i = 0; i < 4; i++) n.next(workers.values)]), ['b', 'c', 'a', 'b']);
  });

  test(
    'the Workers panel lists the ones that need you on top, and leaves everyone else in the order they were hired',
    () {
      final workers = [
        worker('first', WorkerStatus.working, acked: true, createdAt: 1),
        worker('done', WorkerStatus.done, waitingSince: 50, createdAt: 2),
        worker('late', WorkerStatus.needsInput, waitingSince: 300, createdAt: 3),
        worker('last', WorkerStatus.idle, acked: true, createdAt: 4),
        worker('early', WorkerStatus.needsInput, waitingSince: 200, createdAt: 5),
      ];
      expect(ids(needingYou(workers)), ['early', 'late']);
      expect(ids(needyFirst(workers)), ['early', 'late', 'first', 'done', 'last']);
      expect(needyFirst(const []), isEmpty);
    },
  );

  test('a worker someone got to drops out, and one that starts waiting again is new to the round', () {
    final workers = {
      for (final w in [
        worker('a', WorkerStatus.needsInput, waitingSince: 100),
        worker('b', WorkerStatus.needsInput, waitingSince: 200),
        worker('c', WorkerStatus.done, waitingSince: 300),
      ])
        w.id: w,
    };
    final n = NextUp();
    expect(n.next(workers.values)?.id, 'a');
    // Someone answered b: it's back at work, so the next press skips to c.
    workers['b'] = worker('b', WorkerStatus.working);
    expect(n.next(workers.values)?.id, 'c');
    // a asks something else: this round hasn't been to that wait yet.
    workers['a'] = worker('a', WorkerStatus.needsInput, waitingSince: 400);
    expect(n.next(workers.values)?.id, 'a');
    // Been to both: the round starts over, and from a's desk that's c.
    expect(n.next(workers.values, 'a')?.id, 'c');
  });

  test("N skips the worker you're standing at, unless it's the only one waiting", () {
    final workers = [
      worker('a', WorkerStatus.needsInput, waitingSince: 100),
      worker('b', WorkerStatus.done, waitingSince: 200),
    ];
    expect(NextUp().next(workers, 'a')?.id, 'b');
    expect(NextUp().next([workers[0]], 'a')?.id, 'a');
    expect(NextUp().next([worker('x', WorkerStatus.working)]), isNull);
  });

  test('an office from before waitingSince goes by who was hired first', () {
    final old = worker('old', WorkerStatus.done, createdAt: 10);
    final young = worker('young', WorkerStatus.done, createdAt: 20);
    expect(ids(waitingInOrder([young, old])), ['old', 'young']);
  });

  test('the Workers panel counts who needs input and who is done', () {
    expect(
      waitingLabel(
        waitingInOrder([
          worker('a', WorkerStatus.needsInput, waitingSince: 1),
          worker('b', WorkerStatus.needsInput, waitingSince: 2),
          worker('c', WorkerStatus.done, waitingSince: 3),
        ]),
      ),
      '🙋 2 need you · ✅ 1 done',
    );
    expect(waitingLabel([worker('a', WorkerStatus.needsInput, waitingSince: 1)]), '🙋 1 needs you');
    expect(waitingLabel([worker('c', WorkerStatus.done, waitingSince: 3)]), '✅ 1 done');
    expect(waitingLabel([]), '');
  });

  test('the 2D view lists the workers waiting on someone first, then the busy ones, then the rest, asleep last', () {
    final workers = [
      worker('asleep', WorkerStatus.offline, createdAt: 1),
      worker('seen', WorkerStatus.done, waitingSince: 50, acked: true, createdAt: 2),
      worker('ready', WorkerStatus.idle, createdAt: 3),
      worker('late', WorkerStatus.working, createdAt: 9),
      worker('asks', WorkerStatus.needsInput, waitingSince: 300, createdAt: 4),
      worker('early', WorkerStatus.starting, createdAt: 5),
      worker('finished', WorkerStatus.done, waitingSince: 100, createdAt: 6),
      worker('gone', WorkerStatus.exited, createdAt: 0),
    ];
    expect(ids(byUrgency(workers)), ['asks', 'finished', 'early', 'late', 'seen', 'ready', 'gone', 'asleep']);
    expect(byUrgency(const []), isEmpty);
  });
}
