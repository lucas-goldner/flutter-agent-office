import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'agents.dart';

/// What the queue needs from the worker manager. Narrow on purpose, so a smoke test can fake it.
abstract interface class QueueWorkers {
  AgentProvider get defaultProvider;

  /// What a task starts on when whoever queued it didn't pick (⚙️ Settings); the default provider without it.
  AgentChoice? get officeDefault;
  List<WorkerInfo> list();
  bool deskOccupied(String deskId);

  /// The new worker, or why there's none.
  ({WorkerInfo? worker, String? error}) spawn(
    String deskId,
    String by,
    String prompt,
    bool worktree,
    WorkerKind kind,
    AgentProvider provider, [
    String? model,
    AgentEffort? effort,
  ]);

  /// Resolves with a line about what became of the worker's worktree.
  Future<({String? note, String? error})> kill(String id);
}

class QueueEvents {
  const QueueEvents({
    required this.update,
    required this.toast,
    required this.claimIssue,
    required this.refreshGitHub,
    required this.hiringPaused,
    required this.emptied,
    this.room,
    this.worktreeNote,
  });

  final void Function(QueueState state) update;
  final void Function(String text, ToastLevel level) toast;

  /// Mark the issue as taken on GitHub, so the board moves it to In progress. Resolves to an error message when it can't.
  final Future<String?> Function(int issue) claimIssue;

  /// Ask GitHub for fresh pull requests, to pick up the one a worker just opened.
  final void Function() refreshGitHub;

  /// Why no workers may be hired right now (today's budget is spent), if that's so.
  final String? Function() hiringPaused;

  /// The last task on the queue just finished, done: nothing is left queued or running.
  final void Function() emptied;

  /// How many more workers the office has room for under its worker limit (infinity without one).
  final num Function()? room;

  /// What's added after a task that runs in its own worktree ('queue.worktree' in prompts); empty for nothing.
  final String Function()? worktreeNote;
}

const int defaultMaxWorkers = 3;
const int _maxTasks = 100;
const Duration _pumpEvery = Duration(milliseconds: 10000);

/// A worker in one of these states is finished with its task (and can make room for the next one).
const Set<WorkerStatus> _finished = {WorkerStatus.done, WorkerStatus.exited, WorkerStatus.offline};

final Random _random = Random.secure();

String _randomHex(int bytes) =>
    [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

int _now() => DateTime.now().millisecondsSinceEpoch;

/// A [QueueTask] the queue is still changing.
class _Task {
  _Task({
    required this.id,
    this.provider,
    this.model,
    this.effort,
    this.issue,
    required this.title,
    required this.prompt,
    required this.addedBy,
    required this.addedAt,
    required this.status,
    this.workerId,
    this.workerName,
    this.branch,
    this.startedAt,
    this.finishedAt,
    this.outcome,
    this.error,
    this.pr,
  });

  final String id;
  final AgentProvider? provider;
  final String? model;
  final AgentEffort? effort;
  final int? issue;
  final String title;
  final String prompt;
  final String addedBy;
  final int addedAt;
  TaskStatus status;
  String? workerId;
  String? workerName;
  String? branch;
  int? startedAt;
  int? finishedAt;
  TaskOutcome? outcome;
  String? error;
  QueueTaskPr? pr;

  QueueTask get view => QueueTask(
    id: id,
    provider: provider,
    model: model,
    effort: effort,
    issue: issue,
    title: title,
    prompt: prompt,
    addedBy: addedBy,
    addedAt: addedAt,
    status: status,
    workerId: workerId,
    workerName: workerName,
    branch: branch,
    startedAt: startedAt,
    finishedAt: finishedAt,
    outcome: outcome,
    error: error,
    pr: pr,
  );
}

/// The 📋 task queue. Tasks (GitHub issues or free text) wait in order; whenever a desk is free and
/// fewer than `maxWorkers` of them are running, the next one is seated as a worktree worker. A running
/// task finishes when its worker ends its turn, stops, or is sent home. Finished workers stay at
/// their desks to be looked at, until the queue needs the desk for the next task.
class TaskQueue {
  TaskQueue(
    String dataDir,
    this._workers,

    /// Seat workers in their own git worktree (only when the project is a git repo).
    this._useWorktree,
    this._events,
  ) : _statePath = p.join(dataDir, 'queue.json') {
    _restore();
    _timer = Timer.periodic(_pumpEvery, (_) => pump());
  }

  final QueueWorkers _workers;
  final bool _useWorktree;
  final QueueEvents _events;
  final String _statePath;
  List<_Task> _tasks = [];
  int _maxWorkers = defaultMaxWorkers;
  late final Timer _timer;
  bool _pumping = false;
  bool _again = false;

  /// Set on shutdown: the workers' exit events must not seat anyone into a dying office.
  bool _stopped = false;
  final Map<String, WorkerStatus> _lastStatus = {};

  QueueState state() => QueueState(tasks: [for (final t in _tasks) t.view], maxWorkers: _maxWorkers);

  int get limit => _maxWorkers;

  /// Queues a task. With no [provider], it runs on the office's default worker, model and effort included.
  String? add(
    String prompt,
    String by, [
    String? title,
    int? issue,
    AgentProvider? provider,
    String? model,
    AgentEffort? effort,
  ]) {
    if (provider == null) {
      final d = _workers.officeDefault ?? AgentChoice(provider: _workers.defaultProvider);
      provider = d.provider;
      model = d.model;
      effort = d.effort;
    }
    if (provider == AgentProvider.custom && _workers.defaultProvider != AgentProvider.custom) {
      return 'Unknown agent provider';
    }
    final modelError = validateWorkerModel(WorkerKind.agent, provider, model);
    if (modelError != null) return modelError;
    final effortError = validateWorkerEffort(WorkerKind.agent, provider, effort);
    if (effortError != null) return effortError;
    final clean = prompt.replaceAll(RegExp(r'\r\n?'), '\n').trim();
    if (clean.isEmpty) return 'Empty task';
    if (issue != null && _tasks.any((t) => t.issue == issue && t.status != TaskStatus.done)) {
      return 'Issue #$issue is already on the queue';
    }
    if (_tasks.where((t) => t.status != TaskStatus.done).length >= _maxTasks) {
      return 'The queue is full ($_maxTasks tasks)';
    }
    final named = title?.trim() ?? '';
    final heading = named.isNotEmpty ? named : _firstLine(clean);
    final task = _Task(
      id: _randomHex(6),
      provider: provider,
      model: provider == AgentProvider.opencode || provider == AgentProvider.claude ? model : null,
      effort: provider == AgentProvider.claude ? effort : null,
      issue: issue,
      title: heading.length > 120 ? heading.substring(0, 120) : heading,
      prompt: clean,
      addedBy: by,
      addedAt: _now(),
      status: TaskStatus.queued,
    );
    _tasks.add(task);
    _changed();
    pump();
    return null;
  }

  String? remove(String taskId) {
    final t = _find(taskId);
    if (t == null) return 'No such task';
    if (t.status == TaskStatus.running) {
      return '${t.workerName ?? 'Its worker'} is on it — send the worker home to stop it';
    }
    _tasks.remove(t);
    _changed();
    pump();
    return null;
  }

  /// Takes a closed issue's waiting task off the queue (a running one carries on). Returns whether there was one.
  bool dropIssue(int issue) {
    final i = _tasks.indexWhere((t) => t.issue == issue && t.status == TaskStatus.queued);
    if (i < 0) return false;
    _tasks.removeAt(i);
    _changed();
    return true;
  }

  /// Moves a queued task one place up (-1) or down (+1) among the queued tasks.
  void move(String taskId, int delta) {
    final queued = _tasks.where((t) => t.status == TaskStatus.queued).toList();
    final i = queued.indexWhere((t) => t.id == taskId);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= queued.length) return;
    final a = _tasks.indexOf(queued[i]);
    final b = _tasks.indexOf(queued[j]);
    final x = _tasks[a];
    _tasks[a] = _tasks[b];
    _tasks[b] = x;
    _changed();
    pump();
  }

  /// Puts a finished task back at the end of the queue.
  String? retry(String taskId) {
    final t = _find(taskId);
    if (t == null) return 'No such task';
    if (t.status != TaskStatus.done) return 'That task is still on the queue';
    if (t.issue != null && _tasks.any((x) => x != t && x.issue == t.issue && x.status != TaskStatus.done)) {
      return 'Issue #${t.issue} is already on the queue';
    }
    _tasks.remove(t);
    _tasks.add(
      _Task(
        id: t.id,
        provider: t.provider,
        model: t.model,
        effort: t.effort,
        issue: t.issue,
        title: t.title,
        prompt: t.prompt,
        addedBy: t.addedBy,
        addedAt: _now(),
        status: TaskStatus.queued,
      ),
    );
    _changed();
    pump();
    return null;
  }

  /// Forgets the finished tasks.
  void clear() {
    final before = _tasks.length;
    _tasks = _tasks.where((t) => t.status != TaskStatus.done).toList();
    if (_tasks.length != before) _changed();
  }

  void setLimit(num n) {
    if (!n.isFinite) return;
    final v = max(0, min(seats.length, n.floor()));
    if (v == _maxWorkers) return;
    _maxWorkers = v;
    _changed();
    pump();
  }

  /// A worker changed. Cheap unless its status moved, which can free a slot or finish a task.
  void onWorker(WorkerInfo info) {
    if (_lastStatus[info.id] == info.status) return;
    _lastStatus[info.id] = info.status;
    pump();
  }

  void onWorkerGone(String workerId) {
    _lastStatus.remove(workerId);
    pump();
  }

  /// Fresh pull requests from GitHub: link each task to the PR that closes its issue (or came from its branch).
  void onPulls(List<GhPull> pulls) {
    var changed = false;
    for (final t in _tasks) {
      if (t.status == TaskStatus.queued) continue;
      final since = (t.startedAt ?? t.addedAt) - 60000;
      bool fromBranch(GhPull p) => t.branch != null && t.branch!.isNotEmpty && p.headRefName == t.branch;
      final candidates = pulls.where((p) {
        if (fromBranch(p)) return true;
        if (t.issue == null || !p.closes.contains(t.issue)) return false;
        final created = DateTime.tryParse(p.createdAt);
        return created != null && created.millisecondsSinceEpoch >= since;
      }).toList();
      candidates.sort((a, b) {
        final byBranch = (b.headRefName == t.branch ? 1 : 0) - (a.headRefName == t.branch ? 1 : 0);
        return byBranch != 0 ? byBranch : b.createdAt.compareTo(a.createdAt);
      });
      if (candidates.isEmpty) continue;
      final match = candidates.first;
      final pr = QueueTaskPr(
        number: match.number,
        url: match.url,
        state: match.isDraft ? 'DRAFT' : match.state,
        title: match.title,
      );
      final had = t.pr;
      if (had != null && had.number == pr.number && had.state == pr.state && had.title == pr.title) continue;
      t.pr = pr;
      changed = true;
    }
    if (changed) _changed();
  }

  /// Finishes tasks whose worker stopped, then seats queued tasks while there's room.
  void pump() {
    if (_stopped) return;
    if (_pumping) {
      _again = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _again = false;
        _reconcile();
        _seat();
      } while (_again);
    } finally {
      _pumping = false;
    }
  }

  void shutdown() {
    _stopped = true;
    _timer.cancel();
  }

  // ---------------------------------------------------------------------------

  _Task? _find(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _reconcile() {
    final byId = {for (final w in _workers.list()) w.id: w};
    var changed = false;
    var done = false;
    for (final t in _tasks) {
      if (t.status != TaskStatus.running || t.workerId == null) continue;
      final w = byId[t.workerId];
      if (w == null) {
        _finish(t, TaskOutcome.killed);
      } else if (_finished.contains(w.status)) {
        done = _finish(t, w.status == WorkerStatus.done ? TaskOutcome.done : TaskOutcome.exited) || done;
      } else {
        continue;
      }
      changed = true;
    }
    if (!changed) return;
    _changed();
    // A task finishing is what empties the queue; removing or clearing tasks doesn't count.
    if (done && _tasks.every((t) => t.status == TaskStatus.done)) _events.emptied();
  }

  /// Returns whether the task got done (rather than stopping short).
  bool _finish(_Task t, TaskOutcome outcome) {
    t.status = TaskStatus.done;
    t.outcome = outcome;
    t.finishedAt = _now();
    final who = t.workerName ?? 'Its worker';
    if (outcome == TaskOutcome.done) {
      _events.toast('📋 $who finished ${_label(t)}', ToastLevel.info);
      // The worker most likely just opened the PR; go and link it.
      _events.refreshGitHub();
    } else if (outcome == TaskOutcome.exited) {
      _events.toast('📋 $who stopped before finishing ${_label(t)} — requeue it from the queue board', ToastLevel.warn);
    }
    return outcome == TaskOutcome.done;
  }

  /// The queue's own tasks at work: the slots under its limit. Workers hired by hand, board agents and
  /// meetings don't hold one, and nor does a worker left at its prompt after a restart; the office's
  /// worker limit ([QueueEvents.room]) is what caps everyone together.
  int _busyCount() => _tasks.where((t) => t.status == TaskStatus.running).length;

  /// A free desk, else a free bean bag.
  String? _freeDesk() => nextFreeSeat(_workers.deskOccupied)?.id;

  /// No desk or bean bag is free: send home a worker the queue hired whose task is finished (nobody
  /// is looking at its terminal), and return its seat. Workers with a linked PR go first — their work
  /// is delivered.
  String? _recycleDesk() {
    final byId = {for (final w in _workers.list()) w.id: w};
    final candidates =
        [
          for (final t in _tasks)
            if (t.status == TaskStatus.done && t.workerId != null && byId.containsKey(t.workerId))
              (t: t, w: byId[t.workerId]!),
        ].where((c) => _finished.contains(c.w.status) && c.w.viewers.isEmpty).toList()..sort((a, b) {
          final byPr = (b.t.pr != null ? 1 : 0) - (a.t.pr != null ? 1 : 0);
          return byPr != 0 ? byPr : (a.t.finishedAt ?? 0) - (b.t.finishedAt ?? 0);
        });
    if (candidates.isEmpty) return null;
    final pick = candidates.first;
    final done = _workers.kill(pick.w.id);
    _events.toast(
      '📋 ${pick.w.name} went home after ${_label(pick.t)} to make room for the next task',
      ToastLevel.info,
    );
    unawaited(
      done.then((r) {
        if (r.note != null && r.note!.isNotEmpty) _events.toast(r.note!, ToastLevel.info);
        if (r.error != null && r.error!.isNotEmpty) _events.toast(r.error!, ToastLevel.warn);
      }),
    );
    return pick.w.deskId;
  }

  void _seat() {
    var changed = false;
    for (final t in _tasks) {
      if (t.status != TaskStatus.queued) continue;
      if (_busyCount() >= _maxWorkers) break;
      // A spent budget holds the queue instead of failing every task; the pump seats them once hiring resumes.
      final paused = _events.hiringPaused();
      if (paused != null && paused.isNotEmpty) break;
      // So does an office at its worker limit (--max-workers), unless one of the queue's own finished
      // workers going home makes room. Over the limit (it was just lowered), it waits for people to send some home.
      final room = _events.room?.call() ?? double.infinity;
      if (room < 0) break;
      final desk = (room > 0 ? _freeDesk() : null) ?? _recycleDesk();
      if (desk == null) break;
      final note = _useWorktree ? (_events.worktreeNote?.call() ?? prompts['queue.worktree']!.text) : '';
      final r = _workers.spawn(
        desk,
        '${t.addedBy} (queue)',
        note.isNotEmpty ? '${t.prompt}\n\n$note' : t.prompt,
        _useWorktree,
        WorkerKind.agent,
        t.provider ?? _workers.defaultProvider,
        t.model,
        t.effort,
      );
      changed = true;
      final worker = r.worker;
      if (worker == null) {
        final error = r.error ?? 'The worker could not start';
        t.status = TaskStatus.done;
        t.outcome = TaskOutcome.failed;
        t.error = error;
        t.finishedAt = _now();
        _events.toast("📋 Couldn't start ${_label(t)}: $error", ToastLevel.error);
        continue;
      }
      t.status = TaskStatus.running;
      t.workerId = worker.id;
      t.workerName = worker.name;
      t.branch = worker.worktree?.branch;
      t.startedAt = _now();
      t.error = null;
      _lastStatus[worker.id] = worker.status;
      _events.toast(
        '📋 ${worker.name} sat down at ${deskById[desk]?.label ?? 'a desk'} to work on ${_label(t)}',
        ToastLevel.info,
      );
      final issue = t.issue;
      if (issue != null) {
        unawaited(
          _events.claimIssue(issue).then((err) {
            if (err != null && err.isNotEmpty) {
              _events.toast("Couldn't assign issue #$issue on GitHub: $err", ToastLevel.warn);
            }
          }),
        );
      }
    }
    if (changed) _changed();
  }

  void _changed() {
    _persist();
    _events.update(state());
  }

  void _persist() {
    try {
      final json = const JsonEncoder.withIndent('  ').convert({
        'maxWorkers': _maxWorkers,
        'tasks': [for (final t in _tasks) t.view.toJson()],
      });
      _writePrivate(_statePath, json);
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  void _restore() {
    final file = File(_statePath);
    if (!file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync());
      if (saved is! Map) return;
      final maxW = saved['maxWorkers'];
      if (maxW is num && maxW.isFinite) _maxWorkers = max(0, min(seats.length, maxW.floor()));
      final tasks = saved['tasks'];
      for (final s in tasks is List ? tasks : const []) {
        if (s is! Map) continue;
        final id = s['id'];
        final prompt = s['prompt'];
        final title = s['title'];
        if (id is! String || prompt is! String || title is! String) continue;
        final provider = AgentProvider.tryParse(s['provider']) ?? _workers.defaultProvider;
        final status = s['status'] == 'running'
            ? TaskStatus.running
            : s['status'] == 'done'
            ? TaskStatus.done
            : TaskStatus.queued;
        final pr = s['pr'];
        final t = _Task(
          id: id,
          provider: provider,
          model:
              (provider == AgentProvider.opencode && isValidOpenCodeModel(s['model'])) ||
                  (provider == AgentProvider.claude && isClaudeModel(s['model']))
              ? s['model'] as String
              : null,
          effort: provider == AgentProvider.claude ? AgentEffort.tryParse(s['effort']) : null,
          issue: s['issue'] is num ? (s['issue'] as num).toInt() : null,
          title: title,
          prompt: prompt,
          addedBy: s['addedBy'] is String ? s['addedBy'] as String : '?',
          addedAt: s['addedAt'] is num ? (s['addedAt'] as num).toInt() : _now(),
          status: status,
          workerId: s['workerId'] is String ? s['workerId'] as String : null,
          workerName: s['workerName'] is String ? s['workerName'] as String : null,
          branch: s['branch'] is String ? s['branch'] as String : null,
          startedAt: s['startedAt'] is num ? (s['startedAt'] as num).toInt() : null,
          finishedAt: s['finishedAt'] is num ? (s['finishedAt'] as num).toInt() : null,
          outcome: TaskOutcome.tryParse(s['outcome']),
          error: s['error'] is String ? s['error'] as String : null,
          pr: pr is Map ? QueueTaskPr.fromJson(Map<String, dynamic>.from(pr)) : null,
        );
        // Whatever was running died with the old office process; its worker comes back asleep at best.
        if (t.status == TaskStatus.running) {
          t.status = TaskStatus.done;
          t.outcome = TaskOutcome.exited;
          t.finishedAt = _now();
          t.error = 'The office restarted while it was running';
        }
        _tasks.add(t);
      }
    } catch (_) {
      // corrupt state file: start with an empty queue
    }
  }
}

/// Writes [text] to [file] readable by this user only: to `<file>.tmp` first, then moved into place.
void _writePrivate(String file, String text) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(text);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', tmp]);
    } catch (_) {
      // no chmod: the folder around it is private anyway
    }
  }
  File(tmp).renameSync(file);
}

String _label(_Task t) {
  if (t.issue != null) return '#${t.issue}';
  return '“${t.title.length > 40 ? '${t.title.substring(0, 39)}…' : t.title}”';
}

String _firstLine(String s) => s.split('\n')[0].trim();
