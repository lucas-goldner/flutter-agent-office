// The workers waiting on you on this floor, the ones that need you before the ones that are done and
// longest first: N takes you to each in turn (see office/controller.dart), arrows at the edge of the
// screen point to them (ui/compass.dart), and a chip and the Workers panel count them. A port of nextup.ts.

import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart' show isAsleep, isBusy;

import 'notify.dart';

/// Since when it's been waiting (an office from before waitingSince had only the hire time).
int _since(WorkerInfo w) => w.waitingSince ?? w.createdAt;

/// The ones stopped on a question or a permission come first: they can't go on until someone answers.
int _blocked(WorkerInfo w) => w.status == WorkerStatus.needsInput ? 0 : 1;

/// Workers waiting on someone: the ones that need you, then the ones that are done, whoever has waited
/// longest first.
List<WorkerInfo> waitingInOrder(Iterable<WorkerInfo> workers) => workers.where(waitingOnSomeone).toList()
  ..sort((a, b) {
    final n = _blocked(a).compareTo(_blocked(b));
    if (n != 0) return n;
    final s = _since(a).compareTo(_since(b));
    if (s != 0) return s;
    final c = a.createdAt.compareTo(b.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });

/// Workers stopped until someone answers them, whoever has waited longest first.
List<WorkerInfo> needingYou(Iterable<WorkerInfo> workers) =>
    waitingInOrder(workers).where((w) => w.status == WorkerStatus.needsInput).toList();

/// The Workers panel: the ones that need you on top (longest first), everyone else where they've always
/// been, in the order they were hired, so the list only moves when someone's stuck.
List<WorkerInfo> needyFirst(Iterable<WorkerInfo> workers) {
  final all = workers.toList();
  return [
    ...needingYou(all),
    ...all.where((w) => w.status != WorkerStatus.needsInput).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
  ];
}

/// Every worker, as the 2D view lists them: the ones waiting on someone first (see [waitingInOrder]), then
/// the ones at work, then the rest (ready, or done and seen to), asleep last; hired first within each.
List<WorkerInfo> byUrgency(Iterable<WorkerInfo> workers) {
  final all = workers.toList();
  int rank(WorkerInfo w) => isBusy(w.status) ? 0 : (isAsleep(w.status) ? 2 : 1);
  final rest = all.where((w) => !waitingOnSomeone(w)).toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final c = a.createdAt.compareTo(b.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  return [...waitingInOrder(all), ...rest];
}

/// "🙋 2 need you · ✅ 1 done": the ones that need input, then the ones that finished.
String waitingLabel(List<WorkerInfo> waiting) {
  final needs = waiting.where((w) => w.status == WorkerStatus.needsInput).length;
  final done = waiting.length - needs;
  return [if (needs > 0) '🙋 $needs ${needs == 1 ? 'needs' : 'need'} you', if (done > 0) '✅ $done done'].join(' · ');
}

/// One press of N after another: the first worker in line (see [waitingInOrder]) you haven't been to yet
/// this round, and once you've been to them all, the first again. A worker that starts waiting again after
/// you've been to it is new to this round.
class NextUp {
  /// Who this round has been to, and the wait each was on then.
  final Map<String, int> _visited = {};

  /// The one to go to next. [here] is the worker you're standing at, which only comes up if it's the only one.
  WorkerInfo? next(Iterable<WorkerInfo> workers, [String? here]) {
    final waiting = waitingInOrder(workers);
    _visited.removeWhere((id, at) => !waiting.any((w) => w.id == id && _since(w) == at));
    final others = waiting.where((w) => w.id != here).toList();
    var pick = others.where((w) => !_visited.containsKey(w.id)).firstOrNull;
    if (pick == null) {
      _visited.clear();
      pick = others.firstOrNull ?? waiting.firstOrNull;
    }
    if (pick != null) _visited[pick.id] = _since(pick);
    return pick;
  }
}
