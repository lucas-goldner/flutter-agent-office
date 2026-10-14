// How long each worker has spent working (WorkerInfo.workedMs), for its card and the map. Ported
// from upstream's src/server/workers/clock.ts.

import 'package:office_shared/shared.dart';

import 'worker_handle.dart';

/// How long a worker has spent working (ms), the stretch it's in now included.
int? workedMs(LiveInfo info, [int? now]) {
  final since = info.workingSince;
  final ms =
      (info.workedMs ?? 0) + (since == null ? 0 : _atLeast0((now ?? DateTime.now().millisecondsSinceEpoch) - since));
  return ms > 0 ? ms : null;
}

int _atLeast0(int v) => v < 0 ? 0 : v;

/// Keeps count of how long a worker has worked ([LiveInfo.workedMs]) as it goes from its status into [next].
/// [LiveInfo.status]'s setter calls this on every change.
void clockWork(LiveInfo info, WorkerStatus next, [int? now]) {
  final t = now ?? DateTime.now().millisecondsSinceEpoch;
  if (next == WorkerStatus.working) {
    info.workingSince ??= t;
    return;
  }
  if (info.workingSince == null) return;
  info.workedMs = workedMs(info, t);
  info.workingSince = null;
}

/// [workedMs] for a worker as it was sent ([WorkerInfo]), e.g. as it went home.
int? workedMsOf(WorkerInfo info, [int? now]) {
  final since = info.workingSince;
  final ms =
      (info.workedMs ?? 0) + (since == null ? 0 : _atLeast0((now ?? DateTime.now().millisecondsSinceEpoch) - since));
  return ms > 0 ? ms : null;
}
