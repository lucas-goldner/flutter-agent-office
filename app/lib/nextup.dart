// The workers waiting on you on this floor, longest first: N takes you to each in turn (see
// office/controller.dart), arrows at the edge of the screen point to them (ui/compass.dart), and a
// chip counts them. A port of nextup.ts.

import 'package:office_shared/protocol.dart';

import 'notify.dart';

/// Since when it's been waiting (an office from before waitingSince had only the hire time).
int _since(WorkerInfo w) => w.waitingSince ?? w.createdAt;

/// Workers waiting on someone, whoever has waited longest first.
List<WorkerInfo> waitingInOrder(Iterable<WorkerInfo> workers) => workers.where(waitingOnSomeone).toList()
  ..sort((a, b) {
    final s = _since(a).compareTo(_since(b));
    if (s != 0) return s;
    final c = a.createdAt.compareTo(b.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });

/// "🙋 2 waiting · ✅ 1 done": the ones that need input, then the ones that finished.
String waitingLabel(List<WorkerInfo> waiting) {
  final needs = waiting.where((w) => w.status == WorkerStatus.needsInput).length;
  final done = waiting.length - needs;
  return [if (needs > 0) '🙋 $needs waiting', if (done > 0) '✅ $done done'].join(' · ');
}

/// One press of N after another: the longest-waiting worker you haven't been to yet this round, and
/// once you've been to them all, the longest-waiting again. A worker that starts waiting again after
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
