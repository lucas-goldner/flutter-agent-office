import 'dart:async';
import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart' hide Jukebox, Whiteboard;
import 'package:path/path.dart' as p;

import 'agents.dart';
import 'building.dart' show FloorDef;
import 'changes.dart';
import 'config.dart' show excludeFromGit;
import 'court.dart';
import 'decor.dart';
import 'docs.dart';
import 'dog.dart';
import 'github.dart';
import 'jukebox.dart';
import 'queue.dart';
import 'usage.dart' show Ledger;
import 'whiteboard.dart';
import 'workers.dart';

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
}

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
    agentProviders: provider == AgentProvider.custom
        ? const [AgentProvider.claude, AgentProvider.opencode, AgentProvider.codex, AgentProvider.custom]
        : const [AgentProvider.claude, AgentProvider.opencode, AgentProvider.codex],
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
          dog.onWorker(worker);
          _ctx.workerChanged(this, worker.id, worker);
        },
        remove: (workerId) {
          _changes?.forget(workerId);
          _ctx.emit(this, WorkerRemoveMsg(workerId));
          _queue?.onWorkerGone(workerId);
          dog.onWorkerGone(workerId);
          _ctx.workerChanged(this, workerId, null);
        },
        data: (workerId, data, viewers) => _ctx.termData(workerId, data, viewers),
        screen: (workerId, frame) => _ctx.emit(this, frame.toMsg(workerId), true),
        toast: (text, level) => _ctx.toast(this, text, level),
      ),
      _ctx.ledger,
      env: env,
    );

    github = GitHub(def.dir, (state) => _ctx.emit(this, GhIssuesMsg(state)), (state) {
      _ctx.emit(this, GhPullsMsg(state));
      _queue?.onPulls(state.items);
      if (state.loading || state.error != null) return;
      for (final pr in _merges.look(state.items)) {
        _ctx.toast(this, '🎉 PR #${pr.number} merged: ${pr.title}');
        merged(pr.number);
      }
    });
    // The 📋 task queue seats workers by itself: it watches the workers and links PRs from GitHub.
    _queue = TaskQueue(
      dataDir,
      workers,
      project.branch != null && project.branch!.isNotEmpty,
      QueueEvents(
        update: (state) => _ctx.emit(this, QueueMsg(state)),
        toast: (text, level) => _ctx.toast(this, text, level),
        claimIssue: (issue) => github.claim(issue),
        refreshGitHub: () => unawaited(github.refresh()),
        hiringPaused: () => _ctx.ledger.hiringPaused,
        emptied: () {
          _ctx.toast(this, '📋 The queue is empty: every task is done 🎉');
          _ctx.emit(this, const GongMsg(GongWhy.queue));
        },
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
  Changes? _changes;
  WorkerManager get workers => _workers!;
  late final GitHub github;
  TaskQueue get queue => _queue!;
  Changes get changes => _changes!;
  late final Decor decor;
  late final Jukebox jukebox;

  /// The basketball by the hoop: who has it, or its last throw.
  final Court court = Court();

  /// The bookshelf: the project's Markdown files.
  late final Docs docs = Docs(dir);

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

  /// Someone just walked in: boards that haven't been looked at in a while get fetched again.
  void arrived() {
    final fetched = github.issues.fetchedAt > github.pulls.fetchedAt ? github.issues.fetchedAt : github.pulls.fetchedAt;
    if (_now() - fetched > _refreshMs) unawaited(github.refresh());
  }

  bool _active() =>
      _ctx.people(this) > 0 ||
      workers.list().any((w) => isBusy(w.status)) ||
      queue.state().tasks.any((t) => t.status != TaskStatus.done);

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
      workers: ws.length,
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
    dog.stop();
    github.stop();
    queue.shutdown();
    changes.stop();
    whiteboard.flush();
    await workers.shutdown(keep);
  }
}

int _now() => DateTime.now().millisecondsSinceEpoch;
