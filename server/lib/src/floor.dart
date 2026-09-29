import 'dart:async';
import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart' hide Jukebox, MeetingRoom, Whiteboard;
import 'package:path/path.dart' as p;

import 'agents.dart';
import 'building.dart' show FloorDef;
import 'changes.dart';
import 'config.dart' show excludeFromGit;
import 'decor.dart';
import 'dog.dart';
import 'github.dart';
import 'jukebox.dart';
import 'leave_on_merge.dart' show landedWorkers;
import 'machine.dart' show Capacity;
import 'meetings.dart';
import 'prompts.dart';
import 'queue.dart';
import 'usage.dart' show Ledger;
import 'whiteboard.dart';
import 'workers.dart';
import 'worktrees.dart' show Worktrees;

/// What a floor needs from the building around it.
abstract interface class FloorContext {
  String get agentCmd;
  List<String> get agentArgs;
  HookEnv get hook;

  /// Spend, across every floor.
  Ledger get ledger;

  /// To everyone on this floor.
  void emit(Floor floor, ServerMsg msg, [bool droppable]);

  /// [level] defaults to info.
  void toast(Floor floor, String text, [ToastLevel? level]);

  /// A worker's terminal output, for whoever has that terminal open.
  void termData(String workerId, String data, List<String> viewers);

  /// What a worker changed, for whoever has its Changes window open.
  void changes(ChangesState state, List<String> clients);

  /// A worker on this floor changed ([worker] is it now), or left ([worker] is null).
  void workerChanged(Floor floor, String workerId, WorkerInfo? worker);

  /// How many people are on this floor right now.
  int people(Floor floor);

  /// Who's on this floor, and where they stand.
  List<PeerInfo> peers(Floor floor);

  /// The office's worker limit, across every floor.
  Capacity? get capacity;

  /// The office's prompts and the worker everyone starts on, as set in ⚙️ Settings.
  PromptSource? get prompts;

  /// ⚙️ Settings: a worker whose pull request merged goes home by itself.
  bool leaveOnMerge();
}

/// How long after a PR list or a worker's change the office looks for workers whose PR merged.
const _landedDelay = Duration(milliseconds: 1500);

/// Boards on a floor nobody is on, with nothing running, are asked GitHub about this seldom.
const _idleRefreshMs = 10 * 60000;
const _refreshMs = 90000;

/// What `git` says about a checkout: its name, branch and origin for the top bar.
ProjectInfo projectInfo(String dir, String name, String agentCmd, List<String> agentArgs) {
  String? git(List<String> args) {
    try {
      final r = Process.runSync('git', args, workingDirectory: dir);
      return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
    } catch (_) {
      return null;
    }
  }

  final provider = configuredProvider(agentCmd);
  return ProjectInfo(
    name: name,
    dir: dir,
    branch: git(['rev-parse', '--abbrev-ref', 'HEAD']),
    remote: git(['remote', 'get-url', 'origin']),
    agentCmd: [agentCmd, ...agentArgs].join(' '),
    defaultProvider: provider,
    agentProviders: agentProviders(provider),
  );
}

/// One floor of the building: a project's checkout with its own desks and workers, issues and PR
/// boards, task queue, pictures and jukebox, all kept in that checkout's .agent-office folder.
class Floor {
  /// [env] stands in for the office's environment for the workers' terminals (tests).
  Floor(this.def, this._ctx, {Map<String, String>? env}) : id = def.id, dir = def.dir {
    final dataDir = p.join(def.dir, '.agent-office');
    final data = Directory(dataDir);
    if (!data.existsSync()) {
      data.createSync(recursive: true);
      chmodSync(dataDir, 0x1c0); // 0700
    }
    excludeFromGit(def.dir);
    project = projectInfo(def.dir, def.name, _ctx.agentCmd, _ctx.agentArgs);

    // Before the workers, so it hears about the ones who wake up needing input.
    dog = Dog(
      def.id,
      dataDir,
      DogEnv(
        workers: () => _workers?.list() ?? const [],
        people: () => _ctx.peers(this),
        send: (state) => _ctx.emit(this, DogMsg(state)),
      ),
    );

    _workers = WorkerManager(
      def.dir,
      dataDir,
      _ctx.agentCmd,
      _ctx.agentArgs,
      _ctx.hook,
      WorkerEvents(
        update: (worker) {
          _ctx.emit(this, WorkerUpdateMsg(worker));
          // Still being built: the first updates come from waking the workers already at their desks.
          _queue?.onWorker(worker);
          _meetings?.onWorker(worker);
          dog.onWorker(worker);
          _ctx.workerChanged(this, worker.id, worker);
          // Its turn ended, or whoever had its terminal open closed it: it may be free to go now.
          sendLandedHome();
        },
        remove: (workerId) {
          _changes?.forget(workerId);
          _ctx.emit(this, WorkerRemoveMsg(workerId));
          _queue?.onWorkerGone(workerId);
          _meetings?.onWorkerGone(workerId);
          dog.onWorkerGone(workerId);
          _ctx.workerChanged(this, workerId, null);
        },
        data: (workerId, data, viewers) => _ctx.termData(workerId, data, viewers),
        screen: (workerId, frame) => _ctx.emit(this, frame.toMsg(workerId), true),
        toast: (text, level) => _ctx.toast(this, text, level),
      ),
      _ctx.ledger,
      env: env,
      capacity: _ctx.capacity,
      prompts: _ctx.prompts,
    );

    github = GitHub(def.dir, (state) => _ctx.emit(this, GhIssuesMsg(state)), (state) {
      _ctx.emit(this, GhPullsMsg(state));
      _queue?.onPulls(state.items);
      if (state.loading || state.error != null) return;
      for (final pr in _merges.look(state.items)) {
        _ctx.toast(this, '🎉 PR #${pr.number} merged: ${pr.title}');
        merged(pr.number);
      }
      sendLandedHome();
    });
    // The 📋 task queue seats workers by itself: it watches the workers and links PRs from GitHub.
    _queue = TaskQueue(
      dataDir,
      workers,
      project.branch != null && project.branch!.isNotEmpty,
      QueueEvents(
        update: (state) {
          _ctx.emit(this, QueueMsg(state));
          // A task's pull request may just have been linked (or merged).
          sendLandedHome();
        },
        toast: (text, level) => _ctx.toast(this, text, level),
        claimIssue: (issue) => github.claim(issue),
        refreshGitHub: () => unawaited(github.refresh()),
        hiringPaused: () => _ctx.ledger.hiringPaused,
        emptied: () {
          _ctx.toast(this, '📋 The queue is empty: every task is done 🎉');
          _ctx.emit(this, const GongMsg(GongWhy.queue));
        },
        room: () => _ctx.capacity?.room() ?? double.infinity,
        worktreeNote: () => officePrompt(_ctx.prompts, 'queue.worktree'),
      ),
    );

    // Meetings seat their own workers round the meeting room's table and run them round by round.
    _meetings = MeetingRoom(
      def.dir,
      dataDir,
      _FloorMeetingWorkers(workers),
      project.branch != null && project.branch!.isNotEmpty ? GitMeetingTrees(Worktrees(def.dir)) : null,
      MeetingEvents(
        update: (state) => _ctx.emit(this, MeetingMsg(state)),
        toast: (text, level) => _ctx.toast(this, text, level),
        hiringPaused: () => _ctx.ledger.hiringPaused,
        postReview: (pr, file) => github.review(pr, file),
        prompt: (id) => _ctx.prompts?.text(id) ?? prompts[id]!.text,
      ),
    );

    // What each worker changed, for the Changes window at its desk (see changes.dart).
    _changes = Changes(
      def.dir,
      project.branch,
      (workerId) {
        final w = workers.get(workerId);
        if (w == null) return null;
        final wt = w.worktree;
        return ChangesTarget(
          name: w.name,
          cwd: wt != null ? p.join(def.dir, wt.path) : def.dir,
          rel: wt?.path ?? '',
          worktreeBase: wt?.base,
        );
      },
      (branch) {
        for (final pr in github.pulls.items) {
          if (pr.state == 'OPEN' && pr.headRefName == branch) return PrRef(number: pr.number, url: pr.url);
        }
        return null;
      },
      ChangesEvents(
        state: (state, ids) => _ctx.changes(state, ids),
        toast: (text, level) => _ctx.toast(this, text, level),
        refreshGitHub: () => unawaited(github.refresh()),
      ),
    );

    decor = Decor(dataDir);
    jukebox = Jukebox(dataDir);
    whiteboard = Whiteboard(dataDir);
    ready = workers.start();

    unawaited(github.refresh());
    // A floor with people on it, or work under way, keeps its boards fresh; the others check in now and then.
    _timer = Timer.periodic(const Duration(milliseconds: _refreshMs), (_) {
      if (_active() || _now() - github.issues.fetchedAt > _idleRefreshMs) unawaited(github.refresh());
    });
  }

  final FloorDef def;
  final FloorContext _ctx;
  final String id;
  final String dir;
  late final ProjectInfo project;
  WorkerManager? _workers;
  TaskQueue? _queue;
  MeetingRoom? _meetings;
  Changes? _changes;

  /// A look for workers whose pull request merged, due shortly (see [sendLandedHome]).
  Timer? _landedTimer;
  WorkerManager get workers => _workers!;
  late final GitHub github;
  TaskQueue get queue => _queue!;

  /// The meeting room, where workers work through a question together (see meetings.dart).
  MeetingRoom get meetings => _meetings!;
  Changes get changes => _changes!;
  late final Decor decor;
  late final Jukebox jukebox;

  /// The whiteboard everyone on the floor draws on together.
  late final Whiteboard whiteboard;

  /// Completes once the workers whose terminals outlived the last office are picked back up, and the rest woken.
  late final Future<void> ready;
  late final Dog dog;
  late final Timer _timer;

  /// Pull requests merging, to ring the gong for.
  final _merges = MergeWatch();

  /// Pull request [n] merged ([by] someone, from the PR window): the gong rings, once per PR.
  void merged(int n, [String? by]) {
    if (_merges.ring(n)) _ctx.emit(this, GongMsg(GongWhy.merged, pr: n, by: by));
  }

  /// With ⚙️ Settings' *go home once merged* on, sends home every worker whose pull request merged,
  /// once it's at rest and nobody has its terminal open, deleting its worktree and branch unless they
  /// hold work that isn't on GitHub. Called whenever that might have changed; it looks a moment later,
  /// once for a burst of calls, and not from inside the event that prompted it.
  void sendLandedHome() {
    if (_landedTimer != null || !_ctx.leaveOnMerge()) return;
    _landedTimer = Timer(_landedDelay, () {
      _landedTimer = null;
      if (!_ctx.leaveOnMerge() || _closed) return;
      for (final l in landedWorkers(workers.list(), github.pulls.items, queue.state().tasks)) {
        final done = workers.kill(l.worker.id, null, l.head);
        _ctx.toast(this, '🏠 ${l.worker.name} went home: PR #${l.pr} merged');
        unawaited(
          done.then((r) {
            if (r.note != null) _ctx.toast(this, r.note!);
            if (r.error != null) _ctx.toast(this, r.error!, ToastLevel.warn);
          }),
        );
      }
    });
  }

  bool _closed = false;

  /// Someone just walked in: boards that haven't been looked at in a while get fetched again.
  void arrived() {
    final fetched = github.issues.fetchedAt > github.pulls.fetchedAt ? github.issues.fetchedAt : github.pulls.fetchedAt;
    if (_now() - fetched > _refreshMs) unawaited(github.refresh());
  }

  bool _active() =>
      _ctx.people(this) > 0 ||
      workers.list().any((w) => isBusy(w.status)) ||
      queue.state().tasks.any((t) => t.status != TaskStatus.done) ||
      meetings.state().current?.status == MeetingStatus.running;

  FloorInfo info() {
    final ws = workers.list();
    return FloorInfo(
      id: id,
      name: def.name,
      repo: def.repo,
      dir: dir,
      palette: def.palette,
      addedBy: def.addedBy,
      addedAt: def.addedAt,
      workers: ws.where((w) => deskById[w.deskId]?.station == null).length,
      busy: ws.where((w) => w.status == WorkerStatus.working).length,
      waiting: ws
          .where(
            (w) =>
                w.kind == WorkerKind.agent &&
                (w.status == WorkerStatus.needsInput || (w.status == WorkerStatus.done && !w.acked)),
          )
          .length,
      people: _ctx.people(this),
    );
  }

  /// With [keep] (a restart), the workers' terminals keep running for the next office to pick up.
  Future<void> shutdown([bool keep = false]) async {
    _timer.cancel();
    _closed = true;
    _landedTimer?.cancel();
    dog.stop();
    github.stop();
    queue.shutdown();
    meetings.shutdown();
    changes.stop();
    whiteboard.flush();
    await workers.shutdown(keep);
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch;

/// The floor's workers, as the meeting room sees them.
class _FloorMeetingWorkers implements MeetingWorkers {
  _FloorMeetingWorkers(this._w);
  final WorkerManager _w;

  @override
  AgentProvider get defaultProvider => _w.defaultProvider;
  @override
  AgentChoice? get officeDefault => _w.officeDefault;
  @override
  List<WorkerInfo> list() => _w.list();
  @override
  ({WorkerInfo? worker, String? error}) seat(
    String deskId,
    String by,
    String prompt,
    AgentProvider provider,
    String? model,
    AgentEffort? effort,
    ({String id, WorkerWorktree? worktree}) meeting,
  ) => _w.spawn(deskId, by, prompt, false, WorkerKind.agent, provider, model, effort, meeting);
  @override
  String? prompt(String id, String text, [String? by]) => _w.prompt(id, text, by);
  @override
  void write(String id, String data, String by) => _w.write(id, data, by);
  @override
  Future<({String? note, String? error})> kill(String id) => _w.kill(id);
}
