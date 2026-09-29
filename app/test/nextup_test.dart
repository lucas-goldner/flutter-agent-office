import 'package:agent_office/nextup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

WorkerInfo worker(String id, WorkerStatus status, {int? waitingSince, bool acked = false, int createdAt = 0}) => WorkerInfo(
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
  test('three workers waiting: N three times visits each of them, oldest first, then starts over', () {
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
    expect(ids(waitingInOrder(workers.values)), ['a', 'b', 'c']);
    final n = NextUp();
    expect(ids([for (var i = 0; i < 4; i++) n.next(workers.values)]), ['a', 'b', 'c', 'a']);
  });

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
    // a asks something else: it has waited least now, but this round hasn't been to that wait yet.
    workers['a'] = worker('a', WorkerStatus.needsInput, waitingSince: 400);
    expect(n.next(workers.values)?.id, 'a');
    expect(n.next(workers.values)?.id, 'c');
  });

  test("N skips the worker you're standing at, unless it's the only one waiting", () {
    final workers = [worker('a', WorkerStatus.needsInput, waitingSince: 100), worker('b', WorkerStatus.done, waitingSince: 200)];
    expect(NextUp().next(workers, 'a')?.id, 'b');
    expect(NextUp().next([workers[0]], 'a')?.id, 'a');
    expect(NextUp().next([worker('x', WorkerStatus.working)]), isNull);
  });

  test('an office from before waitingSince goes by who was hired first', () {
    final old = worker('old', WorkerStatus.done, createdAt: 10);
    final young = worker('young', WorkerStatus.done, createdAt: 20);
    expect(ids(waitingInOrder([young, old])), ['old', 'young']);
  });

  test('the waiting chip counts who needs input and who is done', () {
    expect(
      waitingLabel(waitingInOrder([
        worker('a', WorkerStatus.needsInput, waitingSince: 1),
        worker('b', WorkerStatus.needsInput, waitingSince: 2),
        worker('c', WorkerStatus.done, waitingSince: 3),
      ])),
      '🙋 2 waiting · ✅ 1 done',
    );
    expect(waitingLabel([worker('c', WorkerStatus.done, waitingSince: 3)]), '✅ 1 done');
    expect(waitingLabel([]), '');
  });
}
