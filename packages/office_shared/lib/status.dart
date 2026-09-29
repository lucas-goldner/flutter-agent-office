// What a worker's status means, for the checks the server and the browser both make.

import 'protocol.dart';

/// Its process isn't running: it exited, or came back asleep after a restart. R wakes it.
bool isAsleep(WorkerStatus status) => status == WorkerStatus.exited || status == WorkerStatus.offline;

/// In the middle of a turn: booting, working, or waiting on an answer.
bool isBusy(WorkerStatus status) =>
    status == WorkerStatus.starting || status == WorkerStatus.working || status == WorkerStatus.needsInput;

/// One line for a notification about a worker: what it's asking for when it needs input, or what it
/// was on when it's done (its last activity may be a permission prompt it has long got past).
String? alertDetail(WorkerInfo w) =>
    w.status == WorkerStatus.needsInput ? (w.activity ?? w.task?.summary) : (w.task?.summary ?? w.prompt);

/// Where a worker's pull request stands: still open, or merged (time to send it home).
enum WorkerPrState { open, merged }

/// A worker's pull request: still open, or merged (time to send it home).
typedef WorkerPr = ({WorkerPrState state, int number});

/// Where its work stands on GitHub: a pull request from its desk, its worktree branch or its queue
/// task is open (one still open wins, e.g. a follow-up on the same branch), or merged, so it can be
/// sent home. Null when it has none, or only closed ones.
WorkerPr? workerPr(WorkerInfo w, List<GhPull> pulls, List<QueueTask> tasks) {
  final mine = <int>{};
  if (w.pr != null) mine.add(w.pr!.number);
  for (final t in tasks) {
    if (t.workerId == w.id && t.pr != null) mine.add(t.pr!.number);
  }
  final seen = <({int number, String state})>[
    for (final p in pulls)
      if (mine.contains(p.number) || (w.worktree != null && w.worktree!.branch == p.headRefName))
        (number: p.number, state: p.state),
  ];
  // Its task's PR can drop off the list GitHub sends (the last 30 merged): keep what the queue saw.
  for (final t in tasks) {
    final pr = t.pr;
    if (t.workerId == w.id && pr != null && !seen.any((p) => p.number == pr.number))
      seen.add((number: pr.number, state: pr.state));
  }
  // Opened from its desk but not on the list yet (still loading, or no gh to ask): it's open.
  final own = w.pr;
  if (own != null && !seen.any((p) => p.number == own.number)) seen.add((number: own.number, state: 'OPEN'));
  final open = seen.where((p) => p.state == 'OPEN' || p.state == 'DRAFT').firstOrNull;
  if (open != null) return (state: WorkerPrState.open, number: open.number);
  final merged = seen.where((p) => p.state == 'MERGED').firstOrNull;
  return merged == null ? null : (state: WorkerPrState.merged, number: merged.number);
}
