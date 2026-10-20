import 'dart:async';
import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart' hide Jukebox, MeetingRoom, Whiteboard;
import 'package:path/path.dart' as p;

import 'agents.dart';
import 'building.dart' show FloorDef;
import 'changes.dart';
import 'codemagic.dart' show CodemagicApi, FloorCodemagic;
import 'config.dart' show excludeFromGit;
import 'court.dart';
import 'decor.dart';
import 'docs.dart';
import 'garage.dart';
import 'floorplan.dart';
import 'dog.dart';
import 'github.dart';
import 'jail.dart';
import 'jukebox.dart';
import 'leave_on_merge.dart' show Landed, landedWork, landedWorkers;
import 'machine.dart' show Capacity;
import 'meetings.dart';
import 'prompts.dart';
import 'queue.dart';
import 'signins.dart' show GhRunAs;
import 'usage.dart' show Ledger;
import 'whiteboard.dart';
import 'workers.dart';
import 'worktrees.dart' show WorktreeCleanup, Worktrees, readBaseBranch;

/// What a floor needs from the building around it.
abstract interface class FloorContext {
  String get agentCmd;
  List<String> get agentArgs;

  /// The DSH profile a DeepSeek Harness worker boots (`--dsh-profile`).
  String get dshProfile;
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

  /// Another floor of the building: a worker across repositories works in its project too (see WorkerInfo.repos).
  Floor? floor(String id);

  /// This floor's pull requests came back: a worker on another floor with a repository here may have landed.
  void pullsChanged(Floor floor);

  /// Whether a worker on another floor works in this floor's project too.
  bool lent(Floor floor);

  /// Whether the building's map locks up workers sent home (see MapPlan.sendHome), instead of letting them go.
  bool locksUp();

  /// Workers hired by an account run on its own sign-ins (see signins.dart).
  RunAs? get runAs;

  /// How to run gh as an account: its own sign-in, the office's (neither set), or why it can't.
  GhRunAs ghAs(String? owner);

  /// Codemagic's API, with the office's token; null without one.
  CodemagicApi? get codemagic;
}

/// The open pull request on a floor's board whose head is [branch].
PrRef? _openPull(Floor floor, String branch) {
  for (final pr in floor.github.pulls.items) {
    if (pr.state == 'OPEN' && pr.headRefName == branch) return PrRef(number: pr.number, url: pr.url);
  }
  return null;
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

    jail = Jail(dataDir);
    // Before the workers and the dog: the back office's desks are only there once it's built.
    plan = FloorPlanStore(dataDir);

    // Before the workers, so it hears about the ones who wake up needing input.
    dog = Dog(
      def.id,
      dataDir,
      DogEnv(
        workers: () => _workers?.list() ?? const [],
        people: () => _ctx.peers(this),
        send: (state) => _ctx.emit(this, DogMsg(state)),
        wing: () => plan.wing,
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
        remove: (workerId, info) {
          _changes?.forget(workerId);
          // Sent home on a map that keeps workers (the castle locks them up, the station puts them out
          // of its airlock): it's kept, for good (a meeting's workers aren't sent home when it's over,
          // just let go).
          final jail = info.meeting == null && _ctx.locksUp()
              ? this.jail.add(id: info.id, name: info.name, color: info.color, workedMs: workedMsOf(info))
              : null;
          _ctx.emit(this, WorkerRemoveMsg(workerId, jail: jail));
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
      dshProfile: _ctx.dshProfile,
      runAs: _ctx.runAs,
    )..builtOut = () => plan.wing;

    github = GitHub(def.dir, (state) => _ctx.emit(this, GhIssuesMsg(state)), (state) {
      _ctx.emit(this, GhPullsMsg(state));
      _queue?.onPulls(state.items);
      if (state.loading || state.error != null) return;
      // A worker may have opened one from a branch it made itself, mid-turn or from a shell.
      unawaited(workers.syncBranches());
      for (final pr in _merges.look(state.items)) {
        _ctx.toast(this, '🎉 PR #${pr.number} merged: ${pr.title}');
        merged(pr.number);
      }
      sendLandedHome();
      _ctx.pullsChanged(this);
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
        claimIssue: (issue, owner) {
          final as = _ctx.ghAs(owner);
          return as.refused != null ? Future.value(as.refused) : github.claim(issue, as.as);
        },
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
        postReview: (pr, file, owner) {
          final as = _ctx.ghAs(owner);
          return as.refused != null ? Future.error(GhError(as.refused!)) : github.review(pr, file, as.as);
        },
        prompt: (id) => _ctx.prompts?.text(id) ?? prompts[id]!.text,
      ),
    );

    // What each worker changed, for the Changes window at its desk (see changes.dart).
    _changes = Changes(
      def.dir,
      readBaseBranch(def.dir) ?? project.branch,
      (workerId, repo) {
        final w = workers.get(workerId);
        if (w == null) return null;
        final wt = w.worktree;
        if (repo == null) {
          return ChangesTarget(
            name: w.name,
            cwd: wt != null ? p.join(def.dir, wt.path) : def.dir,
            rel: wt?.path ?? '',
            worktreeBase: wt?.base,
          );
        }
        // One of the other floors' repositories it works in: diffed against, and PRs opened against, that floor's branch.
        final r = w.repos?.where((x) => x.floor == repo).firstOrNull;
        if (r == null) return null;
        final other = _ctx.floor(r.floor);
        return ChangesTarget(
          name: w.name,
          cwd: p.join(def.dir, r.path),
          rel: r.path,
          worktreeBase: r.base,
          baseBranch: (branch: r.from),
          openPull: (branch) => other != null ? _openPull(other, branch) : null,
          refreshGitHub: () {
            if (other != null) unawaited(other.github.refresh());
          },
        );
      },
      (branch) => _openPull(this, branch),
      ChangesEvents(
        state: (state, ids) => _ctx.changes(state, ids),
        toast: (text, level) => _ctx.toast(this, text, level),
        refreshGitHub: () => unawaited(github.refresh()),
      ),
    );

    decor = Decor(dataDir);
    codemagic = FloorCodemagic(dataDir, _ctx.codemagic);
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

  /// The floor's app on Codemagic and the builds started from the office (the 🏗️ build tower).
  late final FloorCodemagic codemagic;
  late final Jukebox jukebox;

  /// The basketball by the hoop: who has it, or its last throw.
  final Court court = Court();

  /// The cars in the garage: who's in which, and where their drivers have left them.
  final Garage garage = Garage();

  /// The bookshelf: the project's Markdown files.
  late final Docs docs = Docs(dir);

  /// The Markdown and text files in each worker's folder, for its terminal's 📄 File tab.
  final Map<String, Docs> _workerFiles = {};
  Docs? workerFiles(String id) {
    final cwd = workers.cwdOf(id);
    return cwd == null ? null : _workerFiles.putIfAbsent(cwd, () => Docs(cwd, text: true));
  }

  /// The whiteboard everyone on the floor draws on together.
  late final Whiteboard whiteboard;

  /// Completes once the workers whose terminals outlived the last office are picked back up, and the rest woken.
  late final Future<void> ready;
  late final Dog dog;

  /// Workers sent home on a map that keeps them (see MapPlan.sendHome).
  late final Jail jail;

  /// The signs over its desks, and how far its back office is built out.
  late final FloorPlanStore plan;
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
      List<GhPull>? pullsOf(String id) => _ctx.floor(id)?.github.pulls.items;
      for (final l in landedWorkers(workers.list(), github.pulls.items, queue.state().tasks, pullsOf)) {
        final worker = l.worker;
        if (worker.repos?.isEmpty ?? true) {
          _goHome(worker, 'PR #${l.pr} merged', l.head);
          continue;
        }
        // Across repositories, one PR can merge before another repository's work even has one:
        // it goes once nothing is left that its merged PRs didn't deliver.
        if (!_landing.add(worker.id)) continue;
        unawaited(
          workers.holdsWork(worker.id, l.head, l.heads).catchError((_) => true).then((held) {
            _landing.remove(worker.id);
            if (!held && workers.get(worker.id)?.createdAt == worker.createdAt) {
              _goHome(worker, 'its pull requests merged (${l.prs?.join(', ')})', l.head, l.heads);
            }
          }),
        );
      }
    });
  }

  /// Whether a worker's work landed: a pull request of its merged and none is open, on this floor
  /// and, for a worker across repositories, on the others too (see landedWork).
  Landed? landed(WorkerInfo worker) =>
      landedWork(worker, github.pulls.items, queue.state().tasks, (id) => _ctx.floor(id)?.github.pulls.items);

  /// Sends a worker home as someone asked (not by itself, see [sendLandedHome]): with no [cleanup],
  /// its worktree and branch go unless they hold work, where what its merged pull requests delivered
  /// doesn't count. Resolves with the line about its worktree.
  Future<({String? note, String? error})> sendHome(String workerId, [WorktreeCleanup? cleanup]) {
    final info = workers.get(workerId);
    final l = info != null ? landed(info) : null;
    return workers.kill(workerId, cleanup, l?.head, l?.heads);
  }

  /// Workers across repositories whose worktrees are being checked before they go home.
  final _landing = <String>{};

  void _goHome(WorkerInfo worker, String why, [String? head, Map<String, String?>? heads]) {
    final done = workers.kill(worker.id, null, head, heads);
    _ctx.toast(this, '🏠 ${worker.name} went home: $why');
    unawaited(
      done.then((r) {
        if (r.note != null) _ctx.toast(this, r.note!);
        if (r.error != null) _ctx.toast(this, r.error!, ToastLevel.warn);
      }),
    );
  }

  bool _closed = false;

  /// Someone just walked in: boards that haven't been looked at in a while get fetched again.
  void arrived() {
    final fetched = github.issues.fetchedAt > github.pulls.fetchedAt ? github.issues.fetchedAt : github.pulls.fetchedAt;
    if (_now() - fetched > _refreshMs) unawaited(github.refresh());
  }

  bool _active() =>
      _ctx.people(this) > 0 ||
      _ctx.lent(this) ||
      workers.list().any((w) => isBusy(w.status)) ||
      queue.state().tasks.any((t) => t.status != TaskStatus.done) ||
      meetings.state().current?.status == MeetingStatus.running;

  /// 🌿 The base branch changed: Changes diffs against it and its PRs go to it.
  void baseChanged() => _changes?.baseBranch = readBaseBranch(dir) ?? project.branch;

  /// [local]: the project the office was started in (see Building.isLocal).
  FloorInfo info({bool? local}) {
    final ws = workers.list();
    return FloorInfo(
      id: id,
      name: def.name,
      repo: def.repo,
      dir: dir,
      branch: project.branch,
      base: readBaseBranch(dir),
      palette: def.palette,
      local: local,
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
      wing: plan.wing,
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
    ({String id, WorkerWorktree? worktree}) meeting, [
    String? owner,
  ]) => _w.spawn(deskId, by, prompt, false, WorkerKind.agent, provider, model, effort, meeting, const [], owner);
  @override
  String? prompt(String id, String text, [String? by]) => _w.prompt(id, text, by);
  @override
  void write(String id, String data, String by) => _w.write(id, data, by);
  @override
  Future<({String? note, String? error})> kill(String id) => _w.kill(id);
}
