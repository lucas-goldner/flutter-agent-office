// The workers at the desks: each an agent (Claude Code, OpenCode, Codex or a custom command) or a
// shell in a terminal of its own. This runs their terminals through the PTY host (so they outlive a
// restart of the office), reads how they're doing off their hooks and screens, names their tasks,
// books their spend, draws the laptop screens and keeps enough on disk to pick them all back up.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'agents.dart';
import 'github.dart' show gh;
import 'headless.dart';
import 'history.dart';
import 'hook.dart';
import 'lifecycle.dart';
import 'machine.dart' show Capacity;
import 'prompts.dart';
import 'providers/providers.dart';
import 'ptys.dart';
import 'queue.dart' show QueueWorkers;
import 'reported_usage.dart';
import 'services.dart' show ServiceOwner;
import 'stations.dart';
import 'tasks.dart';
import 'usage.dart';
import 'worktrees.dart';

export 'providers/providers.dart' show childEnv;
export 'providers/opencode.dart' show withoutOpenCodeModel;

const _names = [
  'Pixel', 'Byte', 'Nibble', 'Sprocket', 'Widget', 'Gizmo', 'Bolt', 'Cosmo', 'Dot', 'Echo', //
  'Fizz', 'Glitch', 'Hopper', 'Jinx', 'Kilo', 'Lumen', 'Mochi', 'Noodle', 'Orbit', 'Pip', //
  'Quark', 'Rivet', 'Sparky', 'Tofu', 'Uno', 'Volt', 'Waffle', 'Zippy',
];
const _colors = [
  '#ff8a5b', '#5bc0eb', '#9bc53d', '#fde74c', '#c3423f', '#b388eb', '#f7aef8', '#72ddf7', '#ffb400', '#00a6a6', //
];

const _screenInterval = Duration(milliseconds: 250);

/// What a worker with a live terminal can be doing.
const _running = {
  WorkerStatus.starting,
  WorkerStatus.idle,
  WorkerStatus.working,
  WorkerStatus.done,
  WorkerStatus.needsInput,
};
const _keyframeMs = 8000;

/// How often a steady typist's "last typed" time is refreshed for everyone.
const _typedRefreshMs = 15000;

/// How many of a worker's latest prompts and tool calls the task namer sees.
const _taskPrompts = 5;
const _taskTools = 10;

/// While a worker works, refresh its task summary after this many tool calls, at most this often.
const _taskRefreshTools = 8;
const _taskRefreshMs = 90000;
const _prTitleMax = 72;
const _prTaskMax = 2500;

/// How often every worker's transcript is checked for new spend, on top of the hook-driven checks.
const _usageScan = Duration(seconds: 10);

/// How often a terminal with new output is saved to disk, so even a crash loses at most this much.
const _saveScrollback = Duration(seconds: 15);

/// Claude never reporting SessionStart this long after starting: it's stuck on a setup screen.
const _bootGrace = Duration(seconds: 12);

/// Between a worker's saved scrollback and what it prints after the office restarted.
const _restoredNote = '\x1b[2m──── the office restarted · earlier output above ────\x1b[0m\r\n';

/// What a worker whose terminal didn't make it through a restart (the machine rebooted, the terminal
/// host was replaced or died) is resumed with when it was in the middle of something, so it carries on
/// by itself instead of waiting at every desk for someone to type "continue".
const carryOnPrompt =
    'continue — the office restarted and interrupted you. Pick up where you left off; if you were waiting on an answer or a permission, ask again.';

/// Where the workers' hooks reach the office.
class HookEnv {
  const HookEnv({required this.url, required this.token});

  final String url;
  final String token;
}

/// What the workers tell the office about.
class WorkerEvents {
  const WorkerEvents({
    required this.update,
    required this.remove,
    required this.data,
    required this.screen,
    required this.toast,
  });

  final void Function(WorkerInfo info) update;
  final void Function(String workerId) remove;

  /// Terminal output, for the people who have that terminal open (client ids).
  final void Function(String workerId, String data, List<String> viewers) data;

  /// A laptop screen frame.
  final void Function(String workerId, ScreenFrame frame) screen;
  final void Function(String text, ToastLevel level) toast;
}

/// A pull request [WorkerManager.openPr] opened, or found already open.
class OpenedPr {
  const OpenedPr({required this.number, required this.url, required this.existed, required this.dirty});

  final int number;
  final String url;

  /// It was already open (a second press, or one opened by hand).
  final bool existed;

  /// The worktree has uncommitted changes that aren't in it.
  final bool dirty;
}

/// Its terminal in the host as of the last save, and how it was doing, to pick back up after a restart.
class _Saved {
  const _Saved(this.ptyId, this.status, this.acked, [this.waitingSince]);
  final String ptyId;
  final WorkerStatus status;
  final bool acked;
  final int? waitingSince;
}

class _Worker {
  _Worker(this.info, this.tracker, [String? hookToken])
    : hookToken = hookToken ?? _randomHex(16),
      state = info.kind == WorkerKind.agent ? providerAdapter(info.provider)?.createState() : null;

  final LiveInfo info;
  Pty? pty;
  HeadlessTerminal? term;

  /// clientId -> name
  final viewers = <String, String>{};
  bool screenDirty = true;
  List<String> lastLines = [];
  int leftNeedsInputAt = 0;
  int keyframeAt = 0;
  String hookToken;

  /// Claude never reported SessionStart: it's stuck on a trust/login/onboarding screen.
  bool bootBlocked = false;

  /// Its provider's own state on it (see ProviderAdapter.createState).
  final Object? state;

  /// What its provider's adapter is handed of it (see WorkerHandle), once asked for.
  _Handle? handle;

  /// A prompt its start couldn't pass on the command line (a Muse resume): typed into its session after SessionStart.
  String? pendingPrompt;

  /// Test runs and builds that have failed in a row (see failsToDespair).
  int failStreak = 0;

  /// Its latest prompts and tool calls, for naming its task.
  List<String> prompts = [];
  List<String> tools = [];
  int toolsSinceNamed = 0;
  int namedAt = 0;

  /// Bumped by /clear: a new conversation, so a new task.
  int taskEpoch = 0;

  /// Where the session's tokens and cost are read from (see usage.dart).
  final UsageTracker tracker;
  Timer? scanTimer;
  _Saved? saved;

  /// Its process went away mid-turn with the office or the terminal host: its next start carries on
  /// ([carryOnPrompt]).
  bool interrupted = false;

  /// Output since its scrollback was last saved to disk.
  bool unsaved = false;

  /// Where this run's own output starts, below the scrollback carried over from before.
  TermMarker? fresh;
}

/// What a worker's provider adapter is handed of it (see WorkerHandle).
class _Handle implements WorkerHandle {
  _Handle(this._m, this._w);

  final WorkerManager _m;
  final _Worker _w;

  @override
  LiveInfo get info => _w.info;
  @override
  Object? get state => _w.state;
  @override
  bool get running => _w.pty != null;
  @override
  bool get bootBlocked => _w.bootBlocked;
  @override
  set bootBlocked(bool v) => _w.bootBlocked = v;
  @override
  int get leftNeedsInputAt => _w.leftNeedsInputAt;
  @override
  set leftNeedsInputAt(int v) => _w.leftNeedsInputAt = v;
  @override
  int get failStreak => _w.failStreak;
  @override
  set failStreak(int v) => _w.failStreak = v;
  @override
  UsageTracker get tracker => _w.tracker;
  @override
  String? get pendingPrompt => _w.pendingPrompt;
  @override
  set pendingPrompt(String? v) => _w.pendingPrompt = v;
  @override
  void setStatus(WorkerStatus status) => _m._setStatus(_w, status);
  @override
  void emit() => _m._emitUpdate(_w);
  @override
  void persist() => _m._persist();
  @override
  void notePrompt(String prompt) => _m._notePrompt(_w, prompt);
  @override
  void noteTool(String tool) => _m._noteTool(_w, tool);
  @override
  void clearTask() => _m._clearTask(_w);
  @override
  void scheduleScan() => _m._scheduleScan(_w);
  @override
  String? prompt(String text) => _m.prompt(_w.info.id, text);
}

class WorkerManager implements QueueWorkers {
  /// [env] stands in for the office's own environment (tests isolate the workers with it).
  WorkerManager(
    this._dir,
    this._dataDir,
    this._agentCmd,
    this._agentArgs,
    this._hook,
    this._events,
    this._ledger, {
    Map<String, String>? env,

    /// The office's worker limit, across every floor (see machine.dart).
    Capacity? capacity,

    /// The office's prompts and the worker everyone starts on, as set in ⚙️ Settings (see prompts.dart).
    PromptSource? prompts,
  }) : _env = env ?? Platform.environment,
       _capacity = capacity,
       _prompts = prompts,
       defaultProvider = configuredProvider(_agentCmd) {
    _trees = Worktrees(_dir);
    _statePath = p.join(_dataDir, 'workers.json');
    _office = officeCommand();
    final floor = ProviderFloor(dataDir: _dataDir, office: _office, env: _env);
    for (final a in providerAdapters.values) {
      _setups[a.id] = a.prepare(floor);
    }
    _queueBin = _writeQueueCommand();
    _agentPath = resolveCommand(_agentCmd, _env);
    final claude = defaultProvider == AgentProvider.claude ? _agentPath : resolveCommand('claude', _env);
    _namer = TaskNamer(claude, childEnv(_env), (id, task, ctx) {
      final w = _workers[id];
      if (w == null || w.taskEpoch != ctx.epoch) return;
      w.info.task = task;
      _emitUpdate(w);
      _persist();
    }, system: () => officePrompt(_prompts, 'office.namer'));
    _host = PtyHost(
      _dataDir,
      () => _events.toast("The workers' terminal host stopped — resuming them", ToastLevel.warn),
    );
    _scrollback = ScrollbackStore(_dataDir);
    _restore();
    _scrollback.prune(_workers.keys.toSet());
    // A session may have ended (and written its final tally) while the office was down.
    for (final w in _workers.values) {
      _scanUsage(w);
    }
    _screenTimer = Timer.periodic(_screenInterval, (_) => _flushScreens());
    _usageTimer = Timer.periodic(_usageScan, (_) {
      for (final w in List.of(_workers.values)) {
        _scanUsage(w);
      }
    });
    _saveTimer = Timer.periodic(_saveScrollback, (_) {
      for (final w in _workers.values) {
        if (w.unsaved) _saveScrollbackOf(w);
      }
    });
  }

  final String _dir;
  final String _dataDir;
  final String _agentCmd;
  final List<String> _agentArgs;
  final HookEnv _hook;
  final WorkerEvents _events;
  final Ledger _ledger;
  final Map<String, String> _env;
  final Capacity? _capacity;
  final PromptSource? _prompts;

  /// Where the `agent-office` command is, for the board agents' PATH (see [_writeQueueCommand]).
  String? _queueBin;

  final _workers = <String, _Worker>{};
  late final String _statePath;

  /// What each provider set up on this floor, for its launches (see ProviderAdapter.prepare).
  final _setups = <AgentProvider, Object?>{};
  late final Worktrees _trees;
  String? _agentPath;
  @override
  final AgentProvider defaultProvider;

  /// How hooks run the office's own executable (see hook.dart).
  late final List<String> _office;
  late final Timer _screenTimer;

  /// The office is shutting down: workers exiting now are being stopped, not failing to resume.
  bool _closing = false;

  /// Closing for good (Ctrl+C), not restarting: whatever the workers were doing is stopped on purpose.
  bool _stopping = false;
  late final TaskNamer _namer;
  late final Timer _usageTimer;

  /// Runs the workers' terminals outside the office, so they outlive a restart of it (see ptys.dart).
  late final PtyHost _host;

  /// Each worker's terminal on disk, so a restart doesn't wipe it (see history.dart).
  late final ScrollbackStore _scrollback;
  late final Timer _saveTimer;

  /// Picks every worker whose terminal outlived the last office (a dev-server reload, an upgrade)
  /// back up where it is, mid-turn or not. Whoever else was at a desk when the office stopped (a
  /// restart, a crash) gets straight back to work, carrying on with whatever it was in the middle of.
  /// Call once, before anyone can walk in.
  Future<void> start() async {
    await _host.connect();
    await Future.wait([
      for (final w in List.of(_workers.values))
        () async {
          final saved = w.saved;
          w.saved = null;
          final adopted = saved != null ? await _host.attach(saved.ptyId) : null;
          if (adopted == null) return;
          if (_workers[w.info.id] != w) {
            // Sent home while the office was starting.
            adopted.pty.kill();
            return;
          }
          _adopt(w, adopted, saved!);
        }(),
    ]);
    // Terminals nobody saved a claim on (their worker was sent home as the office went down).
    _host.killUnclaimed();
    wakeAll();
  }

  String? get resolvedAgent => _agentPath;

  /// What an agent starts on when whoever starts it doesn't pick: the one set in ⚙️ Settings, or the office's --agent.
  @override
  AgentChoice get officeDefault {
    final picked = _prompts?.agent();
    if (picked != null && (picked.provider != AgentProvider.custom || defaultProvider == AgentProvider.custom)) {
      return picked;
    }
    return AgentChoice(provider: defaultProvider);
  }

  @override
  List<WorkerInfo> list() => [for (final w in _workers.values) w.info.view];

  WorkerInfo? get(String id) => _workers[id]?.info.view;

  /// Each worker's terminal process and directory, to tell whose servers are whose.
  List<ServiceOwner> owners() => [
    for (final w in _workers.values)
      ServiceOwner(
        workerId: w.info.id,
        pid: w.pty != null && w.pty!.pid > 0 ? w.pty!.pid : null,
        agent: w.info.kind == WorkerKind.agent,
        cwd: _cwd(w.info),
        root: _dir,
      ),
  ];

  @override
  bool deskOccupied(String deskId) => _workers.values.any((w) => w.info.deskId == deskId);

  /// Seats a new worker at [deskId]. Returns it, or why there is none as `error`. [meeting] seats one
  /// at the meeting room's table instead, for that meeting (see meetings.dart), in the meeting's own
  /// worktree, which everyone at the table shares.
  @override
  ({WorkerInfo? worker, String? error}) spawn(
    String deskId,
    String by, [
    String? prompt,
    bool worktree = false,
    WorkerKind kind = WorkerKind.agent,
    AgentProvider? provider,
    String? model,
    AgentEffort? effort,
    ({String id, WorkerWorktree? worktree})? meeting,
  ]) {
    ({WorkerInfo? worker, String? error}) fail(String error) => (worker: null, error: error);
    // Nobody picked (a board agent, say): the office's default worker, model and effort included.
    if (kind == WorkerKind.agent && provider == null) {
      final d = officeDefault;
      provider = d.provider;
      model = d.model;
      effort = d.effort;
    }
    final selectedProvider = kind == WorkerKind.agent ? provider : null;
    final modelError = validateWorkerModel(kind, selectedProvider, model);
    if (modelError != null) return fail(modelError);
    final effortError = validateWorkerEffort(kind, selectedProvider, effort);
    if (effortError != null) return fail(effortError);
    final seat = deskById[deskId];
    if (seat == null) return fail('Unknown desk');
    final station = seat.station;
    if (deskOccupied(deskId)) {
      return fail(
        station != null
            ? 'The ${stationAgent[station]!.name} is already there'
            : 'That ${seat.beanbag ? 'bean bag' : 'desk'} is taken',
      );
    }
    if (kind == WorkerKind.shell && station != null) return fail('A board agent is always an agent, not a shell');
    if (station != null && (prompt == null || prompt.trim().isEmpty)) return fail('Tell the board agent what to do');
    if (seat.room != (meeting != null)) {
      return fail(
        seat.room
            ? 'Only a meeting seats workers at the meeting table: call one in the meeting room'
            : 'A meeting seats its workers at the meeting table',
      );
    }
    if (meeting != null && (kind != WorkerKind.agent || worktree)) {
      return fail('A meeting seats agents, in its own worktree');
    }
    if (kind == WorkerKind.shell && provider != null) return fail('Shell workers do not have an agent provider');
    if (kind == WorkerKind.agent &&
        selectedProvider == AgentProvider.custom &&
        defaultProvider != AgentProvider.custom) {
      return fail('Custom is not the configured agent provider');
    }
    if (kind == WorkerKind.agent) {
      final paused = _ledger.hiringPaused;
      if (paused != null) return fail(paused);
    }
    final full = _capacity?.full();
    if (full != null) return fail(full);
    final used = {for (final w in _workers.values) w.info.name.replaceFirst(RegExp(r' 🐚$'), '')};
    final agent = station != null ? stationAgent[station] : null;
    final name =
        agent?.name ?? _names.firstWhere((n) => !used.contains(n), orElse: () => 'Worker ${_workers.length + 1}');
    final id = _randomHex(6);
    WorkerWorktree? wt = meeting?.worktree;
    if (worktree) {
      final made = _trees.create('${name.toLowerCase()}-${id.substring(0, 4)}');
      if (made.error != null) return fail(made.error!);
      wt = made.worktree;
    }
    final trimmed = prompt?.trim();
    final info = LiveInfo(
      id: id,
      kind: kind,
      provider: selectedProvider,
      model: takesModel(selectedProvider) ? model : null,
      effort: takesEffort(selectedProvider) ? effort : null,
      deskId: deskId,
      name: kind == WorkerKind.shell ? '$name 🐚' : name,
      color: kind == WorkerKind.shell ? '#8d99ae' : agent?.color ?? _colors[_random.nextInt(_colors.length)],
      status: WorkerStatus.starting,
      createdBy: by,
      createdAt: _now(),
      prompt: kind == WorkerKind.shell || trimmed == null || trimmed.isEmpty ? null : trimmed,
      worktree: wt,
      activity: prompt != null && prompt.isNotEmpty ? _truncate(prompt, 80) : null,
      meeting: meeting?.id,
    );
    final w = _Worker(info, newTracker());
    _workers[id] = w;
    if (info.prompt != null) _notePrompt(w, info.prompt!);
    // A board agent is told what it's there for ahead of its first request (which is what shows).
    _launch(
      w,
      station != null && info.prompt != null ? '${stationBrief(station, _prompts)}\n\n${info.prompt}' : info.prompt,
      null,
    );
    _persist();
    return (worker: info.view, error: null);
  }

  /// Starts a worker that isn't running again, carrying on its session, with [prompt] as its next
  /// message. Returns why it can't.
  String? resume(String id, [String? prompt]) {
    final w = _workers[id];
    if (w == null) return 'No such worker';
    if (w.pty != null) return 'Worker is already running';
    w.info.status = WorkerStatus.starting;
    w.info.exitCode = null;
    final station = deskById[w.info.deskId]?.station;
    // A board agent with no session to carry on starts over, so it needs telling what it's for again.
    final first = prompt != null && station != null && w.info.sessionId == null
        ? '${stationBrief(station, _prompts)}\n\n$prompt'
        : prompt;
    if (prompt != null) {
      w.info.activity = _truncate(prompt, 80);
      _notePrompt(w, prompt);
    }
    // Cut off mid-turn by a restart: it gets on with it, as whoever was watching would have told it to.
    final carryOn = prompt == null && w.interrupted && w.info.kind == WorkerKind.agent && w.info.sessionId != null;
    w.interrupted = false;
    _launch(w, carryOn ? carryOnPrompt : first, w.info.sessionId);
    return null;
  }

  /// A request for the agent standing by a board (see stations): typed into its session, which is
  /// woken up with it if it's asleep, or it's hired there with it when nobody is. Returns what went
  /// wrong as `error`, or the agent and whether it was just hired.
  ({WorkerInfo? info, bool hired, String? error}) station(String deskId, String by, String text) {
    ({WorkerInfo? info, bool hired, String? error}) fail(String error) => (info: null, hired: false, error: error);
    if (deskById[deskId]?.station == null) return fail('There is no agent to ask there');
    final clean = text.replaceAll(RegExp(r'\r\n?'), '\n').trim();
    if (clean.isEmpty) return fail('Empty prompt');
    final w = _workers.values.where((x) => x.info.deskId == deskId).firstOrNull;
    if (w == null) {
      final r = spawn(deskId, by, clean);
      return r.worker == null ? fail(r.error!) : (info: r.worker, hired: true, error: null);
    }
    // Typed into the question it's asking, the prompt would answer it.
    if (w.info.status == WorkerStatus.needsInput) {
      return fail('The ${w.info.name} is waiting on an answer in its terminal');
    }
    if (w.pty == null) w.info.lastInput = LastInput(by: by, at: _now());
    final err = w.pty != null ? prompt(w.info.id, clean, by) : resume(w.info.id, clean);
    return err != null ? fail(err) : (info: w.info.view, hired: false, error: null);
  }

  /// The worker whose terminal holds this hook token: how a worker proves it's asking for itself.
  WorkerInfo? authenticate(String id, String token) {
    final w = _workers[id];
    return w != null && w.pty != null && token.isNotEmpty && _safeEq(token, w.hookToken) ? w.info.view : null;
  }

  /// Starts every worker that isn't running: nobody should be found asleep at their desk.
  void wakeAll() {
    for (final w in List.of(_workers.values)) {
      if (w.pty == null) resume(w.info.id);
    }
  }

  /// Sends a worker home. For one with its own worktree, [cleanup] says what becomes of it; with no
  /// choice given, the worktree and branch go only when they hold no work, where [landed] (its merged
  /// pull request's head commit) is work delivered. Resolves once that's done, with a line for the
  /// team about the worktree.
  @override
  Future<({String? note, String? error})> kill(String id, [WorktreeCleanup? cleanup, String? landed]) async {
    const none = (note: null, error: null);
    final w = _workers.remove(id);
    if (w == null) return none;
    _namer.forget(id);
    w.scanTimer?.cancel();
    final proc = w.pty;
    w.pty = null; // so the exit handler knows this worker is gone and stays quiet
    try {
      proc?.kill();
    } catch (_) {
      // already gone
    }
    w.term?.dispose();
    _scrollback.remove(id);
    _events.remove(id);
    _persist();
    final wt = w.info.worktree;
    // A meeting's worktree is everyone at the table's: the meeting tidies it away once they've all gone.
    if (wt == null || w.info.meeting != null) return none;
    final name = w.info.name;
    final ref = _ref(wt);
    if (cleanup == null) {
      final work = describeWork(await _trees.inspect(ref, landed));
      if (work.isNotEmpty) return (note: "Kept $name's worktree and branch ${wt.branch} — it has $work", error: null);
      cleanup = WorktreeCleanup.all;
    }
    if (cleanup == WorktreeCleanup.keep) return (note: "Kept $name's worktree and branch ${wt.branch}", error: null);
    final error = await _trees.remove(ref, cleanup);
    if (error != null) return (note: null, error: "Couldn't delete $name's worktree: $error");
    return (
      note: cleanup == WorktreeCleanup.all
          ? "Deleted $name's worktree and branch ${wt.branch}"
          : "Deleted $name's worktree and kept branch ${wt.branch}",
      error: null,
    );
  }

  /// What a worker's worktree holds, so whoever sends it home knows what deleting it would lose.
  Future<WorktreeState?> inspectWorktree(String id) async {
    final wt = _workers[id]?.info.worktree;
    return wt != null ? _trees.inspect(_ref(wt)) : null;
  }

  /// Someone opened a worker's terminal: what to draw in it first.
  ({String data, int cols, int rows})? attach(String id, String clientId, String name) {
    final w = _workers[id];
    if (w == null) return null;
    w.viewers[clientId] = name;
    var changed = _syncViewers(w);
    if (!w.info.acked && w.info.status != WorkerStatus.needsInput) {
      w.info.acked = true;
      changed = true;
    }
    if (changed) _emitUpdate(w);
    final term = w.term;
    final data = term != null ? term.serialize(scrollback: scrollback) : _offlineBanner(w.info);
    return (data: data, cols: w.info.cols, rows: w.info.rows);
  }

  /// Lines of every worker's terminal holding [needle] (a searchKey), newest first, at most [perWorker] each.
  ({List<TerminalHit> hits, bool more}) search(String needle, int perWorker) {
    final hits = <TerminalHit>[];
    var more = false;
    for (final w in _workers.values) {
      final term = w.term;
      if (term == null) continue;
      final found = searchTerminal(term, needle, perWorker);
      more = more || found.more;
      for (final hit in found.hits) {
        hits.add(TerminalHit(workerId: w.info.id, text: hit.text, row: hit.row, rows: hit.rows));
      }
    }
    return (hits: hits, more: more);
  }

  void detach(String id, String clientId) {
    final w = _workers[id];
    if (w == null) return;
    if (w.viewers.remove(clientId) != null && _syncViewers(w)) _emitUpdate(w);
  }

  void detachAll(String clientId) {
    for (final w in _workers.values) {
      if (w.viewers.remove(clientId) != null && _syncViewers(w)) _emitUpdate(w);
    }
  }

  /// Keystrokes from [by]'s browser.
  void write(String id, String data, String by) {
    final w = _workers[id];
    final pty = w?.pty;
    if (w == null || pty == null) return;
    pty.write(data);
    var changed = _typed(w, by);
    if (w.info.status == WorkerStatus.needsInput && !w.info.acked) {
      w.info.acked = true;
      changed = true;
    }
    if (changed) _emitUpdate(w);
  }

  /// Remembers who typed into the terminal last. Says whether that's news: another person, or the
  /// same one after a pause (not every keystroke, or a typist would flood everyone with updates).
  bool _typed(_Worker w, String by) {
    final now = _now();
    final last = w.info.lastInput;
    if (last != null && last.by == by && now - last.at < _typedRefreshMs) return false;
    w.info.lastInput = LastInput(by: by, at: now);
    return true;
  }

  /// Types a prompt into the agent's input box and submits it; [by] is the person who sent it, if
  /// any. Returns why it couldn't.
  String? prompt(String id, String text, [String? by]) {
    final w = _workers[id];
    if (w == null) return 'No such worker';
    final pty = w.pty;
    if (pty == null) return 'Worker is not running';
    final clean = text.replaceAll(RegExp(r'\r\n?'), '\n').trim();
    if (clean.isEmpty) return 'Empty prompt';
    // Bracketed paste keeps multi-line prompts in one message, then Enter submits.
    pty.write('\x1b[200~$clean\x1b[201~');
    Timer(const Duration(milliseconds: 120), () => w.pty?.write('\r'));
    w.info.activity = _truncate(clean, 80);
    _notePrompt(w, clean);
    if (by != null) w.info.lastInput = LastInput(by: by, at: _now());
    _emitUpdate(w);
    return null;
  }

  /// Pushes a worktree worker's branch and opens a pull request for it, with a title and body
  /// drafted from its task. Resolves to the PR, or to an `error` saying why there is none. The
  /// branch may already have an open PR (a second press, or one opened by hand): that one is used.
  Future<({OpenedPr? pr, String? error})> openPr(String id, String by) async {
    ({OpenedPr? pr, String? error}) fail(String error) => (pr: null, error: error);
    final w = _workers[id];
    if (w == null) return fail('No such worker');
    final info = w.info;
    final wt = info.worktree;
    if (wt == null) {
      return fail('${info.name} works in the main checkout — only workers with their own worktree can open a PR');
    }
    if (info.prOpening == true) return fail("${info.name}'s pull request is already being opened");
    if (isBusy(info.status)) {
      final what = info.status == WorkerStatus.needsInput ? 'waiting on input' : info.status.wire;
      return fail("${info.name} is still $what — wait until it's done");
    }
    final cwd = p.join(_dir, wt.path);
    if (!Directory(cwd).existsSync()) return fail("${info.name}'s worktree is gone (${wt.path})");
    info.prOpening = true;
    _emitUpdate(w);
    try {
      final commits = (await _run('git', [
        'log',
        '--reverse',
        '--format=%h %s',
        '${wt.base}..${wt.branch}',
      ], cwd)).split('\n').where((l) => l.isNotEmpty).toList();
      final dirty = (await _run('git', ['status', '--porcelain'], cwd)) != '';
      if (commits.isEmpty) {
        return fail(
          dirty
              ? "${info.name} hasn't committed anything yet — ask it to commit first"
              : '${info.name} has no commits on ${wt.branch} yet',
        );
      }
      final open = await _findOpenPr(wt.branch, cwd);
      if (open != null) {
        info.pr = open;
        _persist();
        return (pr: OpenedPr(number: open.number, url: open.url, existed: true, dirty: dirty), error: null);
      }
      await _run('git', ['push', '-u', 'origin', wt.branch], cwd, 90000);
      final base = await _pushedBranch([wt.from, _trees.currentBranch()], wt.branch);
      final draft = _draftPr(info, commits, by);
      final out = await gh(
        [
          'pr',
          'create',
          '--head',
          wt.branch,
          if (base != null) ...['--base', base],
          '--title',
          draft.title,
          '--body',
          draft.body,
        ],
        cwd,
        60000,
      );
      final url = out.trim().split('\n').last;
      final number = int.tryParse(RegExp(r'/pull/(\d+)').firstMatch(url)?.group(1) ?? '') ?? 0;
      if (number == 0) throw _RunError('gh did not return a pull request URL (${_truncate(out, 120)})');
      info.pr = PrRef(number: number, url: url);
      _persist();
      return (pr: OpenedPr(number: number, url: url, existed: false, dirty: dirty), error: null);
    } catch (err) {
      return fail("Couldn't open a PR for ${info.name}: ${_messageOf(err)}");
    } finally {
      info.prOpening = false;
      // The worker may have been sent home meanwhile; an update would bring it back as a ghost.
      if (_workers[id] == w) _emitUpdate(w);
    }
  }

  /// The first of these branches that exists on origin, for a PR base. None: gh picks the default branch.
  Future<String?> _pushedBranch(List<String?> candidates, String not) async {
    for (final c in candidates) {
      if (c == null || c.isEmpty || c == not) continue;
      try {
        await _run('git', ['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/$c'], _dir);
        return c;
      } catch (_) {
        // not on the remote (or never fetched)
      }
    }
    return null;
  }

  void resize(String id, num cols, num rows) {
    final w = _workers[id];
    final pty = w?.pty;
    final term = w?.term;
    if (w == null || pty == null || term == null) return;
    final c = cols.floor().clamp(20, 400);
    final r = rows.floor().clamp(5, 200);
    if (c == w.info.cols && r == w.info.rows) return;
    w.info.cols = c;
    w.info.rows = r;
    try {
      pty.resize(c, r);
      term.resize(c, r);
    } catch (_) {
      // pty may have exited between checks
    }
    w.screenDirty = true;
    w.lastLines = [];
    _emitUpdate(w);
  }

  /// Claude Code hook callback (a custom --agent that speaks Claude Code's hooks reports here too).
  bool handleHook(String workerId, String token, String event, Object? payload) =>
      handleProviderHook(AgentProvider.claude, workerId, token, event, payload);

  /// Native Codex lifecycle hooks register the root rollout for bounded metric reads.
  bool handleCodexHook(String workerId, String token, String event, Object? payload) =>
      handleProviderHook(AgentProvider.codex, workerId, token, event, payload);

  /// OpenCode plugin callback. The plugin has already filtered child sessions before this bridge.
  bool handleOpenCodeHook(String workerId, String token, Object? payload) =>
      handleProviderHook(AgentProvider.opencode, workerId, token, '', payload);

  /// An event on the hook route /hooks/[route] (see ProviderAdapter.hook): taken only from a running
  /// agent whose provider reports there, with its hook token. Says whether it was taken.
  bool handleProviderHook(AgentProvider route, String workerId, String token, String event, Object? payload) {
    final hook = providerAdapter(route)?.hook;
    final w = _workers[workerId];
    final own = w != null ? providerAdapter(w.info.provider) : null;
    if (hook == null ||
        w == null ||
        w.pty == null ||
        w.info.kind != WorkerKind.agent ||
        own == null ||
        (own.hooksAs ?? own.id) != route ||
        !_safeEq(token, w.hookToken)) {
      return false;
    }
    return hook.handle(_handleOf(w), event, payload);
  }

  /// What a worker's provider adapter is handed of it (see WorkerHandle): made once, kept on the worker.
  WorkerHandle _handleOf(_Worker w) => w.handle ??= _Handle(this, w);

  /// Its provider's adapter, for an agent.
  static ProviderAdapter? _adapterOf(LiveInfo info) =>
      info.kind == WorkerKind.agent ? providerAdapter(info.provider) : null;

  /// The office names its task (see ProviderAdapter.namesTasks).
  static bool _namesTasks(LiveInfo info) => _adapterOf(info)?.namesTasks ?? false;

  /// A new message for the worker: show it right away, and have its task (re)named.
  void _notePrompt(_Worker w, String prompt) {
    if (w.info.kind != WorkerKind.agent) return;
    final clean = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Bare slash commands (/model, /compact), repeats and the office's own carry-on aren't new work.
    if (clean.isEmpty ||
        RegExp(r'^/\S+$').hasMatch(clean) ||
        (w.prompts.isNotEmpty && w.prompts.last == clean) ||
        clean == carryOnPrompt) {
      return;
    }
    w.prompts = _lastN([...w.prompts, clean], _taskPrompts);
    final hadTask = w.info.task != null;
    if (!hadTask) w.info.task = fallbackTask(clean);
    if (!_namesTasks(w.info)) return;
    // "yes", "go ahead", "2": a reply within the same task, not worth a new name.
    if (hadTask && clean.length < 16) return;
    _nameTask(w);
  }

  void _noteTool(_Worker w, String tool) {
    if (!_namesTasks(w.info)) return;
    w.tools = _lastN([...w.tools, tool], _taskTools);
    w.toolsSinceNamed++;
    if (w.info.task != null && w.toolsSinceNamed >= _taskRefreshTools && _now() - w.namedAt > _taskRefreshMs) {
      _nameTask(w);
    }
  }

  void _nameTask(_Worker w) {
    if (!_namesTasks(w.info)) return;
    w.toolsSinceNamed = 0;
    w.namedAt = _now();
    final previous = w.info.task != null && w.prompts.length > 1 ? w.info.task : null;
    _namer.request(
      w.info.id,
      TaskContext(prompts: List.of(w.prompts), tools: List.of(w.tools), previous: previous, epoch: w.taskEpoch),
    );
  }

  void _clearTask(_Worker w) {
    w.taskEpoch++;
    w.prompts = [];
    w.tools = [];
    w.toolsSinceNamed = 0;
    _namer.forget(w.info.id);
    if (w.info.task == null) return;
    w.info.task = null;
    _emitUpdate(w);
    _persist();
  }

  /// The office is closing. On a restart ([keep]), terminals in the host keep running for the next
  /// office to pick back up; otherwise every worker stops.
  Future<void> shutdown([bool keep = false]) async {
    _closing = true;
    _stopping = !keep;
    _screenTimer.cancel();
    _usageTimer.cancel();
    _saveTimer.cancel();
    for (final w in _workers.values) {
      w.scanTimer?.cancel();
      w.scanTimer = null;
      _scanUsage(w);
      // Before the process goes, so the next office shows what it was doing, not how it was stopped.
      if (w.unsaved) _saveScrollbackOf(w);
      if (keep && w.pty?.id != null) continue;
      // A restart only takes this one down because it runs in-process: the next office carries on its turn.
      if (keep && _midTurn(w)) w.interrupted = true;
      try {
        w.pty?.kill();
        // Its exit won't be heard.
        if (w.pty != null) _adapterOf(w.info)?.exited(_handleOf(w), _cwd(w.info));
      } catch (_) {
        // ignore
      }
    }
    _persist();
    if (keep) {
      await _host.detach();
    } else {
      await _host.stop();
    }
  }

  // ---------------------------------------------------------------------------------------------

  void _launch(_Worker w, String? prompt, String? resumeSessionId) {
    final info = w.info;
    // The new terminal starts with what the last one showed (on a resume), or with what was saved
    // when the office last stopped, so earlier output is still there to scroll back to and search.
    final old = w.term;
    final restarted = old == null;
    final before = old != null ? terminalTail(old, scrollback) : _scrollback.load(info.id);
    final prelude = before != null && before.isNotEmpty ? '$before\r\n${restarted ? _restoredNote : ''}' : null;
    final term = _newTerm(w);
    if (prelude != null) {
      // Parsed before anything the new process prints.
      term.write(prelude);
      w.fresh = term.registerMarker();
    }

    final shell = _env['SHELL'] ?? '/bin/bash';
    final isShell = info.kind == WorkerKind.shell;
    final adapter = _adapterOf(info);
    final configured = !isShell && info.provider == defaultProvider;
    final station = deskById[info.deskId]?.station;
    final cwd = _cwd(info);
    final command = _command(info);
    final commandPath = isShell ? null : (configured ? _agentPath : resolveCommand(command, _env));
    final base = isShell ? ['-l'] : (configured ? [..._agentArgs] : <String>[]);
    // Its provider's command line, and anything it sets for this run (see ProviderAdapter.launch).
    final plan = adapter != null
        ? adapter.launch(
            LaunchInput(
              h: _handleOf(w),
              args: base,
              prompt: prompt,
              resumeSessionId: resumeSessionId,
              station: station,
              cwd: cwd,
              setup: _setups[adapter.id],
              env: _env,
            ),
          )
        : LaunchPlan(args: base);
    final args = plan.args;
    if (plan.rotateToken) w.hookToken = _randomHex(16);
    final env = childEnv(_env)
      ..addAll({
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'AGENT_OFFICE_WORKER_ID': info.id,
        'AGENT_OFFICE_HOOK_URL': _hook.url,
        'AGENT_OFFICE_HOOK_TOKEN': w.hookToken,
      })
      ..addAll(plan.env ?? const {});
    // A board agent reaches the queue with the `agent-office queue` command, whichever agent it runs.
    final queueBin = _queueBin;
    if (station != null && queueBin != null) {
      final path = env['PATH'];
      env['PATH'] = path != null && path.isNotEmpty ? '$queueBin:$path' : queueBin;
    }
    adapter?.usage?.locate?.call(_handleOf(w), cwd, env);

    Pty proc;
    try {
      if (!Directory(cwd).existsSync()) throw _RunError('working directory is gone: $cwd');
      plan.finishEnv?.call(env);
      // The host keeps its own copy of the screen for the next office: it starts with the same history.
      SpawnOpts opts(String file, List<String> args) =>
          SpawnOpts(file: file, args: args, cwd: cwd, env: env, cols: info.cols, rows: info.rows, prelude: prelude);
      if (isShell) {
        proc = _host.spawn(opts(shell, args));
      } else if (commandPath != null) {
        proc = _host.spawn(opts(commandPath, args));
      } else {
        // Not found on PATH: let a login shell find it (nvm, asdf, ~/.local/bin ...).
        final line = ['exec', command, for (final a in args) shellQuote(a)].join(' ');
        proc = _host.spawn(opts(shell, ['-l', '-i', '-c', line]));
      }
    } catch (err) {
      _startFailed(w, _messageOf(err));
      return;
    }
    // One that says itself when it's up (see ProviderAdapter.bootHint) starts out 'starting'.
    if (adapter?.bootHint == null) info.status = WorkerStatus.idle;
    _follow(w, proc, term, resumeSessionId);
    _emitUpdate(w);
    _persist();
  }

  /// Takes back a terminal the host kept running while the office was down.
  void _adopt(_Worker w, Adopted adopted, _Saved saved) {
    final info = w.info;
    // It kept working through the restart: nothing to carry on.
    w.interrupted = false;
    info.cols = adopted.cols;
    info.rows = adopted.rows;
    final term = _newTerm(w);
    // Scrollback and all, the history from before this run included: only what it prints from here
    // on can say it's stuck on a login.
    term.write(adopted.snapshot);
    w.fresh = term.registerMarker();
    _setTitle(w, adopted.title);
    // A hook that came in since the office started already says how it's doing.
    if (info.status == WorkerStatus.offline) {
      info.status = saved.status;
      info.acked = saved.acked;
      info.waitingSince = saved.waitingSince;
    }
    final adapter = _adapterOf(info);
    adapter?.usage?.locate?.call(_handleOf(w), _cwd(info), childEnv(_env));
    _follow(w, adopted.pty, term, null);
    // A turn that ended while the office was down says so with its Stop hook, which retries until
    // the office is back. Claude's progress report, where it gives one, says a turn is still going.
    if (adopted.busy && (adapter?.screenProgress ?? false)) _onProgress(w, true);
    _emitUpdate(w);
  }

  /// A fresh screen for a worker's terminal, reading its progress reports (Claude's) and title off it.
  HeadlessTerminal _newTerm(_Worker w) {
    final term = HeadlessTerminal(cols: w.info.cols, rows: w.info.rows);
    // OSC 9;4 progress (Claude Code emits it): catches Esc-cancel, which fires no Stop hook.
    if (providerAdapter(w.info.provider)?.screenProgress ?? false) term.onProgress = (busy) => _onProgress(w, busy);
    term.onTitleChange = (title) => _setTitle(w, title);
    w.term?.dispose();
    w.fresh?.dispose();
    w.term = term;
    w.lastLines = [];
    w.screenDirty = true;
    w.fresh = null;
    return term;
  }

  void _setTitle(_Worker w, String title) {
    final clean = title.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '').trim();
    if (clean.isNotEmpty && clean != w.info.title && !titleNoise(clean)) {
      w.info.title = clean;
      _emitUpdate(w);
    }
  }

  /// Shows a worker's terminal output as it comes, and deals with the process ending.
  void _follow(_Worker w, Pty proc, HeadlessTerminal term, String? resumeSessionId) {
    final info = w.info;
    final adapter = _adapterOf(info);
    w.pty = proc;
    proc.onData((data) {
      term.write(data);
      w.screenDirty = true;
      w.unsaved = true;
      if (w.viewers.isNotEmpty) _events.data(info.id, data, w.viewers.keys.toList());
    });
    proc.onExit((e) {
      // Not for a run it has since replaced.
      if (w.pty == proc || w.pty == null) adapter?.exited(_handleOf(w), _cwd(info));
      if (w.pty != proc || _workers[info.id] != w) return;
      w.pty = null;
      final error = e.error;
      if (error != null) {
        _startFailed(w, error);
        return;
      }
      // The terminal host died and took the process with it: nothing the worker did.
      if (e.lost && !_closing) {
        if (_midTurn(w)) w.interrupted = true;
        resume(info.id);
        return;
      }
      if ((adapter?.usage?.scanOnExit ?? false) && !_closing) _scheduleScan(w);
      // Resuming a conversation Claude no longer has ("No conversation found") exits before Claude
      // ever starts. Start a fresh one rather than leave the worker asleep.
      if ((adapter?.freshIfResumeFails ?? false) &&
          resumeSessionId != null &&
          info.status == WorkerStatus.starting &&
          !_closing) {
        _events.toast("${info.name}'s last conversation couldn't be resumed — starting a fresh one", ToastLevel.warn);
        _launch(w, null, null);
        return;
      }
      info.exitCode = e.exitCode;
      info.status = WorkerStatus.exited;
      final hint = info.kind == WorkerKind.shell
          ? ' — press R to restart'
          : info.sessionId != null
          ? ' — press R to resume'
          : '';
      final msg = '\r\n\x1b[2m[${info.name} exited with code ${e.exitCode}$hint]\x1b[0m\r\n';
      term.write(msg);
      if (w.viewers.isNotEmpty) _events.data(info.id, msg, w.viewers.keys.toList());
      w.screenDirty = true;
      w.unsaved = true;
      _emitUpdate(w);
      _persist();
    });
    // SessionStart fires as soon as Claude can take input. Still silent after a while means it is
    // blocked on a human: folder trust dialog, login, first-run onboarding. Flag it so it jumps.
    Timer(_bootGrace, () {
      if (_closing || info.status != WorkerStatus.starting || w.pty != proc) return;
      final hint = adapter?.bootHint;
      if (hint != null) {
        w.bootBlocked = true;
        info.activity = hint;
        _setStatus(w, WorkerStatus.needsInput);
      } else {
        _setStatus(w, WorkerStatus.idle);
      }
    });
  }

  void _startFailed(_Worker w, String message) {
    final what = _command(w.info);
    final msg = '\r\n\x1b[31mFailed to start $what: $message\x1b[0m\r\n';
    w.info.status = WorkerStatus.exited;
    w.info.exitCode = -1;
    w.term?.write(msg);
    if (w.viewers.isNotEmpty) _events.data(w.info.id, msg, w.viewers.keys.toList());
    w.screenDirty = true;
    w.unsaved = true;
    _events.toast('Could not start $what: $message', ToastLevel.error);
    _emitUpdate(w);
  }

  /// What a worker's terminal runs: the shell, the configured agent command, or another provider's CLI.
  String _command(LiveInfo info) {
    if (info.kind == WorkerKind.shell) return _env['SHELL'] ?? '/bin/bash';
    return providerCommand(info.provider ?? defaultProvider, _agentCmd);
  }

  String _cwd(LiveInfo info) => info.worktree != null ? p.join(_dir, info.worktree!.path) : _dir;

  /// Hooks fire in bursts (every tool call); one read a moment later covers the whole burst.
  void _scheduleScan(_Worker w) {
    if (w.scanTimer != null) return;
    w.scanTimer = Timer(const Duration(milliseconds: 300), () {
      w.scanTimer = null;
      _scanUsage(w);
    });
  }

  /// Picks up what the session logged since last time and books the difference.
  void _scanUsage(_Worker w) {
    final info = w.info;
    final usage = _adapterOf(info)?.usage;
    final scan = usage?.scan;
    if (scan != null) {
      if (_workers[info.id] == w) scan(_handleOf(w));
      return;
    }
    if (usage == null || !usage.transcript || w.tracker.transcript == null || _workers[info.id] != w) return;
    try {
      if (!scanTracker(w.tracker)) return;
    } catch (_) {
      return; // an unreadable transcript is retried on the next scan
    }
    final before = info.usage ?? zeroUsage();
    final after = trackerUsage(w.tracker);
    info.usage = after;
    _ledger.add(addUsage(after, before, -1));
    _emitUpdate(w);
    _persist();
  }

  void _onProgress(_Worker w, bool busy) {
    final s = w.info.status;
    if (busy && (s == WorkerStatus.idle || s == WorkerStatus.done || s == WorkerStatus.starting)) {
      _setStatus(w, WorkerStatus.working);
    }
    // Progress stays busy while a permission prompt is open, so going idle from needs_input means the
    // turn ended without a Stop hook (the prompt was rejected or Esc'd).
    else if (!busy && (s == WorkerStatus.working || (s == WorkerStatus.needsInput && !w.bootBlocked))) {
      _setStatus(w, WorkerStatus.done);
    }
  }

  void _setStatus(_Worker w, WorkerStatus status) {
    if (w.info.status == status) return;
    if (w.info.status == WorkerStatus.needsInput) w.leftNeedsInputAt = _now();
    w.info.status = status;
    // Done, idle or asleep: it's not acting anything out any more.
    if (status != WorkerStatus.working && status != WorkerStatus.needsInput) w.info.action = null;
    // Nobody is looking at the terminal right now -> raise the flag (the worker jumps). A worker at the
    // meeting table that ends its part is waiting on the meeting, not on anyone, so it stays quiet.
    if (status == WorkerStatus.done || status == WorkerStatus.needsInput) {
      w.info.acked = status == WorkerStatus.done && (w.viewers.isNotEmpty || w.info.meeting != null);
      w.info.waitingSince = _now();
    } else {
      w.info.acked = true;
    }
    _emitUpdate(w);
    // What a restarted office picks the worker back up as, should its terminal outlive this one.
    if (w.pty?.id != null) _persist();
  }

  bool _syncViewers(_Worker w) {
    final names = w.viewers.values.toSet().toList();
    final ids = w.viewers.keys.toList();
    bool same(List<String> a, List<String> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    if (same(names, w.info.viewers) && same(ids, w.info.viewerIds)) return false;
    w.info.viewers = names;
    w.info.viewerIds = ids;
    return true;
  }

  void _emitUpdate(_Worker w) => _events.update(w.info.view);

  /// Full screens for every running worker — sent to people as they walk in.
  List<({String workerId, ScreenFrame frame})> fullScreens() {
    final out = <({String workerId, ScreenFrame frame})>[];
    for (final w in _workers.values) {
      final frame = w.term?.snapshotScreen([]);
      if (frame != null) out.add((workerId: w.info.id, frame: frame));
    }
    return out;
  }

  void _flushScreens() {
    final now = _now();
    for (final w in List.of(_workers.values)) {
      final term = w.term;
      if (term == null) continue;
      // Diffs can be dropped for slow clients, so resend the whole screen now and then.
      if (now - w.keyframeAt > _keyframeMs) {
        w.keyframeAt = now;
        w.lastLines = [];
        w.screenDirty = true;
      }
      if (!w.screenDirty) continue;
      w.screenDirty = false;
      _checkBlocked(w);
      final frame = term.snapshotScreen(w.lastLines);
      if (frame != null) _events.screen(w.info.id, frame);
    }
  }

  /// An agent can sit at its prompt without being usable: Claude stuck on a first-run screen, or not
  /// signed in on this machine (see ProviderAdapter.screenBlocked). Flag that as needing a human, and
  /// clear it once the screen moves on.
  void _checkBlocked(_Worker w) {
    final term = w.term;
    final blockedBy = _adapterOf(w.info)?.screenBlocked;
    if (term == null || blockedBy == null) return;
    final s = w.info.status;
    if (s != WorkerStatus.starting && s != WorkerStatus.idle && !(w.bootBlocked && s == WorkerStatus.needsInput)) {
      return;
    }
    // Only this run's output counts: a "Not logged in" in the scrollback from before is old news.
    final text = term.screenText(term.isAlt ? 0 : max(0, w.fresh?.line ?? 0));
    final blocked = blockedBy(text, s == WorkerStatus.starting || w.bootBlocked);
    if (blocked != null && s != WorkerStatus.needsInput) {
      w.bootBlocked = true;
      w.info.activity = blocked;
      _setStatus(w, WorkerStatus.needsInput);
    } else if (blocked == null && w.bootBlocked && s == WorkerStatus.needsInput) {
      w.bootBlocked = false;
      w.info.activity = null;
      _setStatus(w, WorkerStatus.idle);
    }
  }

  /// Writes the `agent-office` command into the data dir's bin/, running the office's own executable,
  /// and returns that directory: on a board agent's PATH, `agent-office queue …` reaches the queue.
  /// Rewritten on every start, so after an upgrade it runs the new install.
  String? _writeQueueCommand() {
    if (Platform.isWindows) return null;
    try {
      final dir = p.join(_dataDir, 'bin');
      Directory(dir).createSync(recursive: true);
      chmodSync(dir, 0x1c0); // 0700
      final file = p.join(dir, 'agent-office');
      final tmp = '$file.tmp';
      File(tmp).writeAsStringSync(
        "#!/bin/sh\n# Agent Office, for the board agents: agent-office queue list|add|remove.\n"
        'exec ${_office.map(shellQuote).join(' ')} "\$@"\n',
      );
      chmodSync(tmp, 0x1c0); // 0700
      File(tmp).renameSync(file);
      return dir;
    } catch (_) {
      return null;
    }
  }

  void _saveScrollbackOf(_Worker w) {
    final term = w.term;
    if (term == null) return;
    w.unsaved = false;
    _scrollback.save(w.info.id, terminalTail(term, scrollback));
  }

  void _persist() {
    final saved = [
      for (final w in _workers.values)
        {
          'id': w.info.id,
          'kind': w.info.kind.wire,
          'provider': ?w.info.provider?.wire,
          'model': ?w.info.model,
          'effort': ?w.info.effort?.wire,
          'deskId': w.info.deskId,
          'name': w.info.name,
          'color': w.info.color,
          'createdBy': w.info.createdBy,
          'createdAt': w.info.createdAt,
          'prompt': ?w.info.prompt,
          'worktree': ?w.info.worktree?.toJson(),
          'title': ?w.info.title,
          'sessionId': ?w.info.sessionId,
          'activity': ?w.info.activity,
          'task': ?w.info.task?.toJson(),
          'pr': ?w.info.pr?.toJson(),
          'meeting': ?w.info.meeting,
          if (w.info.kind == WorkerKind.agent) 'tracker': w.tracker.toJson(),
          if (providerAdapter(w.info.provider)?.usage?.persisted ?? false) 'usage': ?w.info.usage?.toJson(),
          ...?providerAdapter(w.info.provider)?.usage?.save?.call(w.state),
          // A terminal still running in the host, to pick back up after a restart. Its hooks keep the token.
          'hookToken': w.hookToken,
          if (w.pty?.id case final ptyId?)
            'pty': {
              'id': ptyId,
              'status': w.info.status.wire,
              'acked': w.info.acked,
              'waitingSince': ?w.info.waitingSince,
            },
          // In the middle of something: if its terminal doesn't make it through a restart, it carries on after.
          'midTurn': !_stopping && (w.interrupted || _midTurn(w)),
        },
    ];
    try {
      writePrivate(_statePath, const JsonEncoder.withIndent('  ').convert(saved));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  void _restore() {
    final file = File(_statePath);
    if (!file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync());
      if (saved is! List) return;
      for (final s in saved) {
        if (s is! Map) continue;
        final id = s['id'], deskId = s['deskId'];
        if (id is! String || id.isEmpty || deskId is! String || !deskById.containsKey(deskId) || deskOccupied(deskId)) {
          continue;
        }
        final tracker = restoreTracker(s['tracker']);
        final shell = s['kind'] == 'shell';
        final AgentProvider? provider = shell
            ? null
            : AgentProvider.tryParse(s['provider']) ??
                  (tracker.transcript != null ? AgentProvider.claude : defaultProvider);
        final usage = providerAdapter(provider)?.usage;
        final pr = s['pr'];
        final worktree = s['worktree'];
        final info = LiveInfo(
          id: id,
          kind: shell ? WorkerKind.shell : WorkerKind.agent,
          provider: provider,
          model: savedModel(provider, s['model']),
          effort: savedEffort(provider, s['effort']),
          deskId: deskId,
          name: _str(s['name']) ?? 'Worker',
          color: _str(s['color']) ?? _colors[0],
          status: WorkerStatus.offline,
          createdBy: _str(s['createdBy']) ?? '?',
          createdAt: s['createdAt'] is num ? (s['createdAt'] as num).toInt() : _now(),
          prompt: _str(s['prompt']),
          worktree: worktree is Map ? WorkerWorktree.fromJson(Map<String, dynamic>.from(worktree)) : null,
          title: _str(s['title']),
          sessionId: _str(s['sessionId']),
          activity: _str(s['activity']),
          task: _validTask(s['task']),
          pr: pr is Map && pr['number'] is num && pr['url'] is String
              ? PrRef(number: (pr['number'] as num).toInt(), url: pr['url'] as String)
              : null,
          usage: usage != null && usage.persisted
              ? reportedUsage(s['usage'])
              : usage != null && usage.transcript && tracker.transcript != null
              ? trackerUsage(tracker)
              : null,
          meeting: s['meeting'] is String && deskById[deskId]!.room ? s['meeting'] as String : null,
        );
        final token = s['hookToken'];
        final w = _Worker(info, tracker, token is String && token.isNotEmpty ? token : null);
        usage?.restore?.call(w.state, s);
        w.screenDirty = false;
        final pty = s['pty'];
        if (pty is Map && pty['id'] is String) {
          final status = _running.firstWhere((st) => st.wire == pty['status'], orElse: () => WorkerStatus.idle);
          w.saved = _Saved(
            pty['id'] as String,
            status,
            pty['acked'] != false,
            pty['waitingSince'] is num ? (pty['waitingSince'] as num).toInt() : null,
          );
        }
        // Mid-turn as the office went down: cut off, unless its terminal is picked back up still
        // running (adopt). An office from before midTurn only said so for a terminal in the host.
        final midTurn = s['midTurn'];
        w.interrupted = midTurn is bool
            ? midTurn
            : pty is Map && (pty['status'] == 'working' || pty['status'] == 'needs_input');
        final prompt = info.prompt;
        if (prompt != null) w.prompts = [prompt.replaceAll(RegExp(r'\s+'), ' ').trim()];
        _workers[info.id] = w;
      }
    } catch (_) {
      // corrupt state file: start fresh
    }
  }
}

// -----------------------------------------------------------------------------------------------

/// In the middle of a turn: working, or asking something (not stuck on a trust or login screen).
bool _midTurn(_Worker w) => midTurn(w.info, w.bootBlocked);

final _random = Random.secure();

String _randomHex(int bytes) =>
    [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

int _now() => DateTime.now().millisecondsSinceEpoch;

String? _str(Object? v) => v is String ? v : null;

List<String> _lastN(List<String> xs, int n) => xs.length > n ? xs.sublist(xs.length - n) : xs;

WorktreeRef _ref(WorkerWorktree wt) => WorktreeRef(path: wt.path, branch: wt.branch, base: wt.base);

WorkerTask? _validTask(Object? t) => t is Map && t['name'] is String && t['summary'] is String
    ? WorkerTask(name: t['name'] as String, summary: t['summary'] as String)
    : null;

bool _executable(String file) {
  try {
    final st = File(file).statSync();
    return st.type == FileSystemEntityType.file && (st.mode & 0x49) != 0; // any x bit
  } catch (_) {
    return false;
  }
}

/// The absolute path of [cmd]: as given when it has a slash, else found on PATH, else as a login
/// shell finds it (nvm, asdf, ~/.local/bin ...). Null when it's nowhere. [env] stands in for the
/// office's environment.
String? resolveCommand(String cmd, [Map<String, String>? env]) {
  env ??= Platform.environment;
  if (cmd.contains('/')) return _executable(cmd) ? p.normalize(p.absolute(cmd)) : null;
  final onPath = _onPath(cmd, env);
  if (onPath != null) return onPath;
  try {
    final shell = env['SHELL'] ?? '/bin/bash';
    final line = ['-l', '-i', '-c', 'command -v ${shellQuote(cmd)}'];
    // An interactive login shell runs the user's rc files, which could hang: never wait on it long.
    final timeout = _onPath('timeout', env);
    final r = timeout != null
        ? Process.runSync(timeout, ['-k', '1', '5', shell, ...line], environment: env, includeParentEnvironment: false)
        : Process.runSync(shell, line, environment: env, includeParentEnvironment: false);
    final out = '${r.stdout}'.trim().split('\n');
    final found = out.isEmpty ? '' : out.last.trim();
    if (found.startsWith('/')) return found;
  } catch (_) {
    // fall through
  }
  return null;
}

/// [cmd] on PATH only.
String? _onPath(String cmd, Map<String, String> env) {
  for (final dir in (env['PATH'] ?? '').split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    final path = p.join(dir, cmd);
    if (_executable(path)) return path;
  }
  return null;
}

String _offlineBanner(LiveInfo info) {
  final hint = info.kind == WorkerKind.shell
      ? ' Press R to restart it.'
      : info.sessionId != null
      ? ' Press R to resume the session.'
      : '';
  return '\x1b[2m${info.name} is not running.$hint\x1b[0m\r\n';
}

class _RunError implements Exception {
  _RunError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _messageOf(Object err) => switch (err) {
  _RunError(:final message) => message,
  ProcessException(:final message) => message.isNotEmpty ? message : '$err',
  FileSystemException(:final message, :final osError) => osError?.message ?? message,
  _ => '$err',
};

/// Runs a command without blocking the office; throws with the last lines of its stderr.
Future<String> _run(String cmd, List<String> args, String cwd, [int timeout = 30000]) async {
  Process proc;
  try {
    proc = await Process.start(cmd, args, workingDirectory: cwd);
  } on ProcessException catch (e) {
    throw _RunError(e.message.isNotEmpty ? e.message : '$cmd failed');
  }
  proc.stdin.close().ignore();
  var killed = false;
  final timer = Timer(Duration(milliseconds: timeout), () {
    killed = true;
    proc.kill();
  });
  final out = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final err = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
  final code = await proc.exitCode;
  timer.cancel();
  final stdout = await out, stderr = await err;
  if (code != 0 || killed) {
    final text = stderr.trim().isNotEmpty ? stderr : 'Command failed: $cmd ${args.join(' ')}';
    final lines = text.trim().split('\n').where((l) => l.isNotEmpty).toList();
    final last = lines.sublist(lines.length > 2 ? lines.length - 2 : 0).join(' ');
    throw _RunError(last.isNotEmpty ? last : '$cmd failed');
  }
  return stdout.trim();
}

Future<PrRef?> _findOpenPr(String branch, String cwd) async {
  final out = await gh([
    'pr',
    'list',
    '--head',
    branch,
    '--state',
    'open',
    '--limit',
    '1',
    '--json',
    'number,url',
  ], cwd);
  final list = jsonDecode(out.trim().isEmpty ? '[]' : out);
  if (list is! List || list.isEmpty || list.first is! Map) return null;
  final found = list.first as Map;
  return PrRef(number: (found['number'] as num).toInt(), url: '${found['url']}');
}

/// A pull request title and body from what the worker was asked to do. The title is the issue's
/// title when the task came off the issues board, else the task's first line; the body carries the
/// task, the commits, a "Closes #n" when the task asked for one, and which desk it came from.
({String title, String body}) _draftPr(LiveInfo info, List<String> commits, String by) {
  final task = (info.prompt ?? '').replaceAll(RegExp(r'\r\n?'), '\n').trim();
  final firstLine = task.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  // The issues board hands work over as: Work on GitHub issue #12: "Title".
  final issue = RegExp(r'\bissue #(\d+):\s*["“](.+?)["”]\.?\s*$', caseSensitive: false).firstMatch(firstLine);
  String? nonEmpty(String? s) => s != null && s.isNotEmpty ? s : null;
  final title = _truncate(
    nonEmpty(issue?.group(2)) ??
        nonEmpty(firstLine.replaceFirst(RegExp(r'[.:;,]+$'), '')) ??
        nonEmpty(commits.isNotEmpty ? commits.first.replaceFirst(RegExp(r'^\S+\s+'), '') : null) ??
        nonEmpty(info.worktree?.branch) ??
        info.name,
    _prTitleMax,
  );
  final closes =
      RegExp(
        r'\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b[^\n]{0,40}?#(\d+)',
        caseSensitive: false,
      ).firstMatch(task)?.group(1) ??
      issue?.group(1);
  final parts = <String>[];
  if (task.isNotEmpty) parts.add('## Task\n\n${task.length > _prTaskMax ? '${task.substring(0, _prTaskMax)}…' : task}');
  String commitLine(String c) {
    final i = c.indexOf(' ');
    final hash = i < 0 ? c.substring(0, max(0, c.length - 1)) : c.substring(0, i);
    return '- `$hash` ${c.substring(i + 1)}';
  }

  parts.add('## Commits\n\n${commits.map(commitLine).join('\n')}');
  if (closes != null) parts.add('Closes #$closes');
  parts.add('_Opened from Agent Office by $by · ${info.name} at ${deskById[info.deskId]?.label ?? info.deskId}_');
  return (title: title, body: parts.join('\n\n'));
}

String _truncate(String s, int n) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > n ? '${one.substring(0, n - 1)}…' : one;
}

/// Compares two strings in time that doesn't depend on where they differ.
bool _safeEq(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}
