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
import 'codex.dart';
import 'codex_usage.dart';
import 'github.dart' show gh;
import 'headless.dart';
import 'history.dart';
import 'hook.dart';
import 'opencode.dart';
import 'ptys.dart';
import 'queue.dart' show QueueWorkers;
import 'reported_usage.dart';
import 'services.dart' show ServiceOwner;
import 'tasks.dart';
import 'usage.dart';
import 'worktrees.dart';

const _names = [
  'Pixel', 'Byte', 'Nibble', 'Sprocket', 'Widget', 'Gizmo', 'Bolt', 'Cosmo', 'Dot', 'Echo', //
  'Fizz', 'Glitch', 'Hopper', 'Jinx', 'Kilo', 'Lumen', 'Mochi', 'Noodle', 'Orbit', 'Pip', //
  'Quark', 'Rivet', 'Sparky', 'Tofu', 'Uno', 'Volt', 'Waffle', 'Zippy',
];
const _colors = [
  '#ff8a5b', '#5bc0eb', '#9bc53d', '#fde74c', '#c3423f', '#b388eb', '#f7aef8', '#72ddf7', '#ffb400', '#00a6a6', //
];

// Env vars from a parent agent session (e.g. starting the office from inside Claude Code) that
// would make a worker think it is a child session — that silently turns off transcript saving,
// which breaks resume.
const _scrubEnv = {
  'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SSE_PORT', 'CLAUDE_CODE_EXECPATH', 'CLAUDE_PID', //
  'CLAUDE_EFFORT', 'CODEX_THREAD_ID', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE', //
  'NO_COLOR', 'FORCE_COLOR', 'VSCODE_INJECTION', 'TERM_PROGRAM', 'TERM_PROGRAM_VERSION',
};
const _scrubPrefixes = [
  'CLAUDE_CODE_SESSION',
  'CLAUDE_CODE_CHILD',
  'CLAUDE_CODE_MESSAGING',
  'NEBULA_',
  'AGENT_OFFICE_',
];
bool _scrubbed(String k) => _scrubEnv.contains(k) || _scrubPrefixes.any(k.startsWith);

const _screenInterval = Duration(milliseconds: 250);

/// What a worker with a live terminal can be doing.
const _running = {
  WorkerStatus.starting,
  WorkerStatus.idle,
  WorkerStatus.working,
  WorkerStatus.done,
  WorkerStatus.needsInput,
};
const _latePromptGraceMs = 5000;
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

/// The Claude Code hooks the office listens to (see [WorkerManager.handleHook]).
const _claudeHookEvents = [
  'SessionStart',
  'UserPromptSubmit',
  'Stop',
  'Notification',
  'PermissionRequest',
  'PreToolUse',
  'PostToolUse',
];

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

/// A worker's [WorkerInfo], as it changes. The wire type is immutable; this is copied into one for
/// every update.
class _Info {
  _Info({
    required this.id,
    required this.kind,
    this.provider,
    this.model,
    required this.deskId,
    required this.name,
    required this.color,
    required this.status,
    required this.createdBy,
    required this.createdAt,
    this.prompt,
    this.worktree,
    this.title,
    this.sessionId,
    this.activity,
    this.task,
    this.pr,
    this.usage,
  });

  final String id;
  final WorkerKind kind;
  final AgentProvider? provider;
  final String? model;
  final String deskId;
  final String name;
  final String color;
  WorkerStatus status;
  bool acked = true;
  final String createdBy;
  final int createdAt;
  final String? prompt;
  final WorkerWorktree? worktree;
  PrRef? pr;
  bool? prOpening;
  String? title;
  String? sessionId;
  int? exitCode;
  int cols = 100;
  int rows = 30;
  List<String> viewers = const [];
  String? activity;
  WorkerTask? task;
  Usage? usage;
  LastInput? lastInput;

  WorkerInfo get view => WorkerInfo(
    id: id,
    kind: kind,
    provider: provider,
    model: model,
    deskId: deskId,
    name: name,
    color: color,
    status: status,
    acked: acked,
    createdBy: createdBy,
    createdAt: createdAt,
    prompt: prompt,
    worktree: worktree,
    pr: pr,
    prOpening: prOpening,
    title: title,
    sessionId: sessionId,
    exitCode: exitCode,
    cols: cols,
    rows: rows,
    viewers: List.unmodifiable(viewers),
    activity: activity,
    task: task,
    usage: usage,
    lastInput: lastInput,
  );
}

/// Its terminal in the host as of the last save, and how it was doing, to pick back up after a restart.
class _Saved {
  const _Saved(this.ptyId, this.status, this.acked);
  final String ptyId;
  final WorkerStatus status;
  final bool acked;
}

class _Worker {
  _Worker(this.info, this.tracker, [String? hookToken]) : hookToken = hookToken ?? _randomHex(16);

  final _Info info;
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

  /// OpenCode errors keep the desk visibly actionable until a new turn starts.
  bool openCodeError = false;
  CodexUsageReader codexUsage = CodexUsageReader();
  String? codexHome;
  String? codexTranscript;
  final codexTools = <String, String>{};
  final codexPending = <String>{};
  bool codexPermissionUnknown = false;

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

  /// Output since its scrollback was last saved to disk.
  bool unsaved = false;

  /// Where this run's own output starts, below the scrollback carried over from before.
  TermMarker? fresh;
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
  }) : _env = env ?? Platform.environment,
       defaultProvider = configuredProvider(_agentCmd) {
    _trees = Worktrees(_dir);
    _statePath = p.join(_dataDir, 'workers.json');
    _settingsPath = p.join(_dataDir, 'claude-hooks.json');
    _office = officeCommand();
    _writeHookSettings();
    _openCodePlugin = writeOpenCodePlugin(_dataDir);
    _agentPath = resolveCommand(_agentCmd, _env);
    final claude = defaultProvider == AgentProvider.claude ? _agentPath : resolveCommand('claude', _env);
    _namer = TaskNamer(claude, childEnv(_env), (id, task, ctx) {
      final w = _workers[id];
      if (w == null || w.taskEpoch != ctx.epoch) return;
      w.info.task = task;
      _emitUpdate(w);
      _persist();
    });
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

  final _workers = <String, _Worker>{};
  late final String _statePath;
  late final String _settingsPath;
  late final Worktrees _trees;
  String? _agentPath;
  @override
  final AgentProvider defaultProvider;
  late final String _openCodePlugin;

  /// How hooks run the office's own executable (see hook.dart).
  late final List<String> _office;
  late final Timer _screenTimer;

  /// The office is shutting down: workers exiting now are being stopped, not failing to resume.
  bool _closing = false;
  late final TaskNamer _namer;
  late final Timer _usageTimer;

  /// Runs the workers' terminals outside the office, so they outlive a restart of it (see ptys.dart).
  late final PtyHost _host;

  /// Each worker's terminal on disk, so a restart doesn't wipe it (see history.dart).
  late final ScrollbackStore _scrollback;
  late final Timer _saveTimer;

  /// Picks every worker whose terminal outlived the last office (a dev-server reload, an upgrade)
  /// back up where it is, mid-turn or not. Whoever else was at a desk when the office stopped (a
  /// restart, a crash) gets straight back to work. Call once, before anyone can walk in.
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

  /// Seats a new worker at [deskId]. Returns it, or why there is none as `error`.
  @override
  ({WorkerInfo? worker, String? error}) spawn(
    String deskId,
    String by, [
    String? prompt,
    bool worktree = false,
    WorkerKind kind = WorkerKind.agent,
    AgentProvider? provider,
    String? model,
  ]) {
    ({WorkerInfo? worker, String? error}) fail(String error) => (worker: null, error: error);
    final selectedProvider = kind == WorkerKind.agent ? provider ?? defaultProvider : null;
    final modelError = validateWorkerModel(kind, selectedProvider, model);
    if (modelError != null) return fail(modelError);
    final seat = deskById[deskId];
    if (seat == null) return fail('Unknown desk');
    if (deskOccupied(deskId)) return fail('That ${seat.beanbag ? 'bean bag' : 'desk'} is taken');
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
    final used = {for (final w in _workers.values) w.info.name.replaceFirst(RegExp(r' 🐚$'), '')};
    final name = _names.firstWhere((n) => !used.contains(n), orElse: () => 'Worker ${_workers.length + 1}');
    final id = _randomHex(6);
    WorkerWorktree? wt;
    if (worktree) {
      final made = _trees.create('${name.toLowerCase()}-${id.substring(0, 4)}');
      if (made.error != null) return fail(made.error!);
      wt = made.worktree;
    }
    final trimmed = prompt?.trim();
    final info = _Info(
      id: id,
      kind: kind,
      provider: selectedProvider,
      model: selectedProvider == AgentProvider.opencode ? model : null,
      deskId: deskId,
      name: kind == WorkerKind.shell ? '$name 🐚' : name,
      color: kind == WorkerKind.shell ? '#8d99ae' : _colors[_random.nextInt(_colors.length)],
      status: WorkerStatus.starting,
      createdBy: by,
      createdAt: _now(),
      prompt: kind == WorkerKind.shell || trimmed == null || trimmed.isEmpty ? null : trimmed,
      worktree: wt,
      activity: prompt != null && prompt.isNotEmpty ? _truncate(prompt, 80) : null,
    );
    final w = _Worker(info, newTracker());
    _workers[id] = w;
    if (info.prompt != null) _notePrompt(w, info.prompt!);
    _launch(w, info.prompt, null);
    _persist();
    return (worker: info.view, error: null);
  }

  /// Starts a worker that isn't running again, resuming its conversation. Returns why it can't.
  String? resume(String id) {
    final w = _workers[id];
    if (w == null) return 'No such worker';
    if (w.pty != null) return 'Worker is already running';
    w.info.status = WorkerStatus.starting;
    w.info.exitCode = null;
    _launch(w, null, w.info.sessionId);
    return null;
  }

  /// Starts every worker that isn't running: nobody should be found asleep at their desk.
  void wakeAll() {
    for (final w in List.of(_workers.values)) {
      if (w.pty == null) resume(w.info.id);
    }
  }

  /// Sends a worker home. For one with its own worktree, [cleanup] says what becomes of it; with no
  /// choice given, the worktree and branch go only when they hold no work. Resolves once that's done,
  /// with a line for the team about the worktree.
  @override
  Future<({String? note, String? error})> kill(String id, [WorktreeCleanup? cleanup]) async {
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
    if (wt == null) return none;
    final name = w.info.name;
    final ref = _ref(wt);
    if (cleanup == null) {
      final work = describeWork(await _trees.inspect(ref));
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

  /// Claude Code hook callback.
  bool handleHook(String workerId, String token, String event, Object? payload) {
    final w = _workers[workerId];
    if (w == null ||
        w.pty == null ||
        w.info.kind != WorkerKind.agent ||
        (w.info.provider != AgentProvider.claude && w.info.provider != AgentProvider.custom) ||
        !_safeEq(token, w.hookToken)) {
      return false;
    }
    final m = payload is Map ? payload : const {};
    final now = _now();
    final sessionId = m['session_id'];
    if (sessionId is String && sessionId.isNotEmpty && sessionId != w.info.sessionId) {
      w.info.sessionId = sessionId;
      _persist();
    }
    final transcript = m['transcript_path'];
    if (transcript is String && transcript != w.tracker.transcript) {
      w.tracker.transcript = transcript;
      _persist();
    }
    _scheduleScan(w);
    switch (event) {
      case 'SessionStart':
        if (m['source'] == 'clear') _clearTask(w);
        if (w.info.status == WorkerStatus.starting || (w.bootBlocked && w.info.status == WorkerStatus.needsInput)) {
          w.bootBlocked = false;
          _setStatus(w, WorkerStatus.idle);
        }
      case 'UserPromptSubmit':
        w.bootBlocked = false;
        final prompt = m['prompt'];
        if (prompt is String) {
          w.info.activity = _truncate(prompt, 80);
          _notePrompt(w, prompt);
        }
        if (w.info.status != WorkerStatus.working) {
          _setStatus(w, WorkerStatus.working);
        } else {
          _emitUpdate(w);
        }
      case 'PreToolUse':
        if (m['tool_name'] == 'AskUserQuestion') {
          _setStatus(w, WorkerStatus.needsInput);
        } else {
          final activity = _describeTool(m);
          w.info.activity = activity;
          _noteTool(w, activity);
          if (w.info.status != WorkerStatus.working) {
            _setStatus(w, WorkerStatus.working);
          } else {
            _emitUpdate(w);
          }
        }
      case 'PostToolUse':
        if (w.info.status == WorkerStatus.needsInput) {
          w.leftNeedsInputAt = now;
          _setStatus(w, WorkerStatus.working);
        }
      case 'PermissionRequest':
        w.info.activity = 'Wants permission: ${_describeTool(m)}';
        _setStatus(w, WorkerStatus.needsInput);
      case 'Notification':
        final type = m['notification_type'];
        if (type == 'permission_prompt') {
          if (now - w.leftNeedsInputAt > _latePromptGraceMs) _setStatus(w, WorkerStatus.needsInput);
        } else if (type == 'idle_prompt') {
          if (w.info.status == WorkerStatus.working) _setStatus(w, WorkerStatus.done);
        }
      case 'Stop':
        _setStatus(w, WorkerStatus.done);
    }
    return true;
  }

  /// Native Codex lifecycle hooks register the root rollout for bounded metric reads.
  bool handleCodexHook(String workerId, String token, String event, Object? payload) {
    final w = _workers[workerId];
    if (w == null ||
        w.pty == null ||
        w.info.kind != WorkerKind.agent ||
        w.info.provider != AgentProvider.codex ||
        !_safeEq(token, w.hookToken)) {
      return false;
    }
    final report = normalizeCodexHook(event, payload);
    if (report == null) return false;
    final info = w.info;
    if (info.sessionId != null && info.sessionId != report.sessionId && event != 'SessionStart') return false;
    if (info.sessionId == null || info.sessionId != report.sessionId) {
      if (info.sessionId != null) {
        _clearTask(w);
        info.usage = null;
        w.codexTranscript = null;
        w.codexUsage = CodexUsageReader();
      }
      info.sessionId = report.sessionId;
      _persist();
    }
    if (report.transcriptPath != null) w.codexTranscript = report.transcriptPath;
    _scheduleScan(w);
    w.bootBlocked = false;
    void clearPending() {
      w.codexTools.clear();
      w.codexPending.clear();
      w.codexPermissionUnknown = false;
    }

    void busy() => _setStatus(
      w,
      w.codexPending.isNotEmpty || w.codexPermissionUnknown ? WorkerStatus.needsInput : WorkerStatus.working,
    );
    switch (report.event) {
      case 'SessionStart':
        clearPending();
        if (report.source == 'clear') _clearTask(w);
        info.activity = null;
        if (info.status == WorkerStatus.starting || info.status == WorkerStatus.needsInput) {
          _setStatus(w, WorkerStatus.idle);
        }
      case 'UserPromptSubmit':
        clearPending();
        final prompt = report.prompt;
        if (prompt != null) {
          info.activity = _truncate(prompt, 80);
          _notePrompt(w, prompt);
        }
        _setStatus(w, WorkerStatus.working);
      case 'PreToolUse':
        final tool = report.tool;
        info.activity = tool != null ? _truncate(tool, 80) : 'Using a tool';
        final toolUseId = report.toolUseId;
        if (toolUseId != null && w.codexTools.length < 256) w.codexTools[toolUseId] = tool ?? '';
        if (RegExp(r'(?:^|[.])(?:AskUserQuestion|request_user_input)$').hasMatch(tool ?? '')) {
          if (toolUseId != null) {
            w.codexPending.add(toolUseId);
          } else {
            w.codexPermissionUnknown = true;
          }
        }
        busy();
      case 'PermissionRequest':
        info.activity = 'Wants permission: ${_truncate(report.tool ?? 'tool', 80)}';
        // PermissionRequest has no tool_use_id in the native schema. Keep every matching
        // active call pending so an unrelated parallel tool cannot dismiss the prompt.
        final candidates = [
          for (final e in w.codexTools.entries)
            if (e.value == report.tool) e.key,
        ];
        if (candidates.isEmpty) w.codexPermissionUnknown = true;
        w.codexPending.addAll(candidates);
        _setStatus(w, WorkerStatus.needsInput);
      case 'PostToolUse':
        final toolUseId = report.toolUseId;
        if (toolUseId != null) {
          w.codexTools.remove(toolUseId);
          w.codexPending.remove(toolUseId);
        }
        busy();
      case 'Stop':
      case 'Interrupt':
        clearPending();
        _setStatus(w, WorkerStatus.done);
    }
    _emitUpdate(w);
    _persist();
    return true;
  }

  /// OpenCode plugin callback. The plugin has already filtered child sessions before this bridge.
  bool handleOpenCodeHook(String workerId, String token, Object? payload) {
    final w = _workers[workerId];
    if (w == null ||
        w.pty == null ||
        w.info.kind != WorkerKind.agent ||
        w.info.provider != AgentProvider.opencode ||
        !_safeEq(token, w.hookToken)) {
      return false;
    }
    final info = w.info;
    if (payload is Map && payload['type'] == 'usage') {
      final usage = reportedUsage(payload['usage']);
      if (usage == null || info.sessionId == null || payload['sessionId'] != info.sessionId) return false;
      // Full snapshots replace previous totals. They never advance task status or enter the Claude ledger.
      info.usage = usage;
      _emitUpdate(w);
      _persist();
      return true;
    }
    final ev = _openCodeEvent(payload);
    if (ev == null) return false;
    final starting = ev.type == 'session' && ev.status == OpenCodeHookStatus.starting;
    if (info.sessionId != null && info.sessionId != ev.sessionId && !starting) return false;
    if (info.sessionId == null || (starting && info.sessionId != ev.sessionId)) {
      final switching = info.sessionId != null;
      info.sessionId = ev.sessionId;
      if (switching) {
        info.usage = null;
        _clearTask(w);
        info.activity = null;
        _setStatus(w, WorkerStatus.idle);
      }
      w.openCodeError = false;
      _persist();
    }
    final prompt = ev.prompt;
    final hasPrompt = prompt != null && prompt.isNotEmpty;
    if (ev.type == 'error') {
      w.openCodeError = true;
    } else if (ev.status == OpenCodeHookStatus.working || hasPrompt) {
      w.openCodeError = false;
    }
    if (hasPrompt) {
      info.activity = _truncate(prompt, 80);
      _notePrompt(w, prompt);
    } else if (ev.tool != null && ev.tool!.isNotEmpty) {
      info.activity = _truncate(ev.tool!, 80);
    } else if (ev.detail != null && ev.detail!.isNotEmpty) {
      info.activity = _truncate(ev.detail!, 80);
    }
    if (ev.status == OpenCodeHookStatus.needsInput) {
      _setStatus(w, WorkerStatus.needsInput);
    } else if (ev.status == OpenCodeHookStatus.working) {
      _setStatus(w, WorkerStatus.working);
    } else if (ev.status == OpenCodeHookStatus.done && w.pty != null) {
      _setStatus(w, w.openCodeError ? WorkerStatus.needsInput : WorkerStatus.done);
    } else if (ev.status == OpenCodeHookStatus.starting && info.status == WorkerStatus.starting) {
      _setStatus(w, WorkerStatus.idle);
    } else {
      _emitUpdate(w);
    }
    return true;
  }

  static bool _claudeLike(_Info info) => info.provider == AgentProvider.claude || info.provider == AgentProvider.custom;

  /// A new message for the worker: show it right away, and have its task (re)named.
  void _notePrompt(_Worker w, String prompt) {
    if (w.info.kind != WorkerKind.agent) return;
    final clean = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Bare slash commands (/model, /compact) and repeats aren't new work.
    if (clean.isEmpty || RegExp(r'^/\S+$').hasMatch(clean) || (w.prompts.isNotEmpty && w.prompts.last == clean)) {
      return;
    }
    w.prompts = _lastN([...w.prompts, clean], _taskPrompts);
    final hadTask = w.info.task != null;
    if (!hadTask) w.info.task = fallbackTask(clean);
    if (!_claudeLike(w.info)) return;
    // "yes", "go ahead", "2": a reply within the same task, not worth a new name.
    if (hadTask && clean.length < 16) return;
    _nameTask(w);
  }

  void _noteTool(_Worker w, String tool) {
    if (!_claudeLike(w.info)) return;
    w.tools = _lastN([...w.tools, tool], _taskTools);
    w.toolsSinceNamed++;
    if (w.info.task != null && w.toolsSinceNamed >= _taskRefreshTools && _now() - w.namedAt > _taskRefreshMs) {
      _nameTask(w);
    }
  }

  void _nameTask(_Worker w) {
    if (!_claudeLike(w.info)) return;
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
      try {
        w.pty?.kill();
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
    final provider = info.provider;
    final isClaude = !isShell && provider == AgentProvider.claude;
    final isOpenCode = !isShell && provider == AgentProvider.opencode;
    final isCodex = !isShell && provider == AgentProvider.codex;
    final configured = !isShell && provider == defaultProvider;
    final command = _command(info);
    final commandPath = isShell ? null : (configured ? _agentPath : resolveCommand(command, _env));
    var args = isShell ? ['-l'] : (configured ? [..._agentArgs] : <String>[]);
    if (isClaude) {
      args.insertAll(0, ['--settings', _settingsPath]);
      if (resumeSessionId != null) args.addAll(['--resume', resumeSessionId]);
      // `--` so a prompt like "- fix login" is never parsed as a CLI option.
      if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt]);
    } else if (isOpenCode) {
      if (resumeSessionId != null || info.model != null) args = withoutOpenCodeModel(args);
      if (resumeSessionId == null && info.model != null) args.addAll(['--model', info.model!]);
      if (resumeSessionId != null) args.addAll(['--session', resumeSessionId]);
      if (prompt != null && prompt.isNotEmpty) args.addAll(['--prompt', prompt]);
    } else if (isCodex) {
      args.addAll([...codexHookArgs(_office), '--no-alt-screen']);
      if (resumeSessionId != null) args.addAll(['resume', resumeSessionId]);
      if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt]);
    }
    if (isCodex) {
      w.codexTools.clear();
      w.codexPending.clear();
      w.codexPermissionUnknown = false;
    }
    if (isOpenCode || isCodex) {
      w.hookToken = _randomHex(16);
      w.openCodeError = false;
    }
    final env = childEnv(_env)
      ..addAll({
        'TERM': 'xterm-256color',
        'COLORTERM': 'truecolor',
        'AGENT_OFFICE_WORKER_ID': info.id,
        'AGENT_OFFICE_HOOK_URL': _hook.url,
        'AGENT_OFFICE_HOOK_TOKEN': w.hookToken,
      });

    final cwd = _cwd(info);
    if (isCodex) w.codexHome = _codexHome(cwd, env);
    Pty proc;
    try {
      if (!Directory(cwd).existsSync()) throw _RunError('working directory is gone: $cwd');
      if (isOpenCode) {
        env['AGENT_OFFICE_SESSION_ID'] = resumeSessionId ?? '';
        env['OPENCODE_CONFIG_CONTENT'] = mergeOpenCodeConfigContent(
          env['OPENCODE_CONFIG_CONTENT'],
          openCodePluginSpecifier(_openCodePlugin),
        );
      }
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
    if (!isClaude && !isCodex) info.status = WorkerStatus.idle;
    _follow(w, proc, term, resumeSessionId);
    _emitUpdate(w);
    _persist();
  }

  /// Takes back a terminal the host kept running while the office was down.
  void _adopt(_Worker w, Adopted adopted, _Saved saved) {
    final info = w.info;
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
    }
    if (info.provider == AgentProvider.codex) w.codexHome = _codexHome(_cwd(info), childEnv(_env));
    _follow(w, adopted.pty, term, null);
    // A turn that ended while the office was down says so with its Stop hook, which retries until
    // the office is back. Claude's progress report, where it gives one, says a turn is still going.
    if (adopted.busy && info.provider == AgentProvider.claude) _onProgress(w, true);
    _emitUpdate(w);
  }

  /// A fresh screen for a worker's terminal, reading Claude's progress and title off it.
  HeadlessTerminal _newTerm(_Worker w) {
    final term = HeadlessTerminal(cols: w.info.cols, rows: w.info.rows);
    // OSC 9;4 progress (Claude Code emits it): catches Esc-cancel, which fires no Stop hook.
    if (w.info.provider == AgentProvider.claude) term.onProgress = (busy) => _onProgress(w, busy);
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
    if (clean.isNotEmpty &&
        clean != w.info.title &&
        !RegExp(r'^claude( code)?$', caseSensitive: false).hasMatch(clean)) {
      w.info.title = clean;
      _emitUpdate(w);
    }
  }

  /// Shows a worker's terminal output as it comes, and deals with the process ending.
  void _follow(_Worker w, Pty proc, HeadlessTerminal term, String? resumeSessionId) {
    final info = w.info;
    final isClaude = info.kind == WorkerKind.agent && info.provider == AgentProvider.claude;
    final isCodex = info.kind == WorkerKind.agent && info.provider == AgentProvider.codex;
    w.pty = proc;
    proc.onData((data) {
      term.write(data);
      w.screenDirty = true;
      w.unsaved = true;
      if (w.viewers.isNotEmpty) _events.data(info.id, data, w.viewers.keys.toList());
    });
    proc.onExit((e) {
      if (w.pty != proc || _workers[info.id] != w) return;
      w.pty = null;
      final error = e.error;
      if (error != null) {
        _startFailed(w, error);
        return;
      }
      // The terminal host died and took the process with it: nothing the worker did.
      if (e.lost && !_closing) {
        resume(info.id);
        return;
      }
      if (isCodex && !_closing) _scheduleScan(w);
      // Resuming a conversation Claude no longer has ("No conversation found") exits before Claude
      // ever starts. Start a fresh one rather than leave the worker asleep.
      if (isClaude && resumeSessionId != null && info.status == WorkerStatus.starting && !_closing) {
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
      if (isClaude || isCodex) {
        w.bootBlocked = true;
        info.activity = isCodex
            ? 'Open the terminal: complete login and review Office hooks in /hooks'
            : 'Waiting on a setup prompt (trust / login) — open the terminal';
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
  String _command(_Info info) {
    if (info.kind == WorkerKind.shell) return _env['SHELL'] ?? '/bin/bash';
    return info.provider == defaultProvider ? _agentCmd : info.provider?.wire ?? _agentCmd;
  }

  String _cwd(_Info info) => info.worktree != null ? p.join(_dir, info.worktree!.path) : _dir;

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
    if (info.kind == WorkerKind.agent && info.provider == AgentProvider.codex) {
      final transcript = w.codexTranscript, home = w.codexHome, session = info.sessionId;
      if (_workers[info.id] != w || transcript == null || home == null || session == null) return;
      final usage = w.codexUsage.read(transcript, session, home);
      if (usage != null && jsonEncode(usage.toJson()) != jsonEncode(info.usage?.toJson())) {
        info.usage = usage;
        _emitUpdate(w);
        _persist();
      }
      return;
    }
    if (info.kind != WorkerKind.agent || !_claudeLike(info) || w.tracker.transcript == null || _workers[info.id] != w) {
      return;
    }
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
    // Nobody is looking at the terminal right now -> raise the flag (the worker jumps).
    if (status == WorkerStatus.done || status == WorkerStatus.needsInput) {
      w.info.acked = w.viewers.isNotEmpty && status == WorkerStatus.done;
    } else {
      w.info.acked = true;
    }
    _emitUpdate(w);
    // What a restarted office picks the worker back up as, should its terminal outlive this one.
    if (w.pty?.id != null) _persist();
  }

  bool _syncViewers(_Worker w) {
    final names = w.viewers.values.toSet().toList();
    final cur = w.info.viewers;
    var same = names.length == cur.length;
    for (var i = 0; same && i < names.length; i++) {
      same = names[i] == cur[i];
    }
    if (same) return false;
    w.info.viewers = names;
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

  /// Claude can sit at its prompt without being usable: stuck on a first-run screen, or not signed
  /// in on this machine. Flag that as needing a human, and clear it once the screen moves on.
  void _checkBlocked(_Worker w) {
    final term = w.term;
    if (w.info.kind != WorkerKind.agent || term == null || !_claudeLike(w.info)) return;
    final s = w.info.status;
    if (s != WorkerStatus.starting && s != WorkerStatus.idle && !(w.bootBlocked && s == WorkerStatus.needsInput)) {
      return;
    }
    // Only this run's output counts: a "Not logged in" in the scrollback from before is old news.
    final text = term.screenText(term.isAlt ? 0 : max(0, w.fresh?.line ?? 0));
    final loggedOut = _notLoggedIn.hasMatch(text);
    final blocked = loggedOut || (_setupPrompt.hasMatch(text) && (s == WorkerStatus.starting || w.bootBlocked));
    if (blocked && s != WorkerStatus.needsInput) {
      w.bootBlocked = true;
      w.info.activity = loggedOut
          ? "Claude isn't signed in on this machine — open the terminal and type /login"
          : 'Waiting on a setup prompt (trust / login) — open the terminal';
      _setStatus(w, WorkerStatus.needsInput);
    } else if (!blocked && w.bootBlocked && s == WorkerStatus.needsInput) {
      w.bootBlocked = false;
      w.info.activity = null;
      _setStatus(w, WorkerStatus.idle);
    }
  }

  /// Claude Code's settings for the workers: every hook POSTs to the office (see hook.dart).
  void _writeHookSettings() {
    final hooks = <String, Object>{
      for (final event in _claudeHookEvents)
        event: [
          {
            'hooks': [
              {'type': 'command', 'command': claudeHookCommand(event, office: _office)},
            ],
          },
        ],
    };
    _writePrivate(_settingsPath, const JsonEncoder.withIndent('  ').convert({'hooks': hooks}));
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
          if (w.info.kind == WorkerKind.agent) 'tracker': w.tracker.toJson(),
          if (w.info.provider == AgentProvider.opencode || w.info.provider == AgentProvider.codex)
            'usage': ?w.info.usage?.toJson(),
          if (w.info.provider == AgentProvider.codex) 'codexTranscript': ?w.codexTranscript,
          // A terminal still running in the host, to pick back up after a restart. Its hooks keep the token.
          'hookToken': w.hookToken,
          if (w.pty?.id case final ptyId?) 'pty': {'id': ptyId, 'status': w.info.status.wire, 'acked': w.info.acked},
        },
    ];
    try {
      _writePrivate(_statePath, const JsonEncoder.withIndent('  ').convert(saved));
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
        final claudeLike = provider == AgentProvider.claude || provider == AgentProvider.custom;
        final pr = s['pr'];
        final worktree = s['worktree'];
        final info = _Info(
          id: id,
          kind: shell ? WorkerKind.shell : WorkerKind.agent,
          provider: provider,
          model: provider == AgentProvider.opencode && isValidOpenCodeModel(s['model']) ? s['model'] as String : null,
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
          usage: provider == AgentProvider.opencode || provider == AgentProvider.codex
              ? reportedUsage(s['usage'])
              : claudeLike && tracker.transcript != null
              ? trackerUsage(tracker)
              : null,
        );
        final token = s['hookToken'];
        final w = _Worker(info, tracker, token is String && token.isNotEmpty ? token : null);
        if (provider == AgentProvider.codex && s['codexTranscript'] is String) {
          w.codexTranscript = s['codexTranscript'] as String;
        }
        w.screenDirty = false;
        final pty = s['pty'];
        if (pty is Map && pty['id'] is String) {
          final status = _running.firstWhere((st) => st.wire == pty['status'], orElse: () => WorkerStatus.idle);
          w.saved = _Saved(pty['id'] as String, status, pty['acked'] != false);
        }
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

final _random = Random.secure();

String _randomHex(int bytes) =>
    [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();

int _now() => DateTime.now().millisecondsSinceEpoch;

String? _str(Object? v) => v is String ? v : null;

List<String> _lastN(List<String> xs, int n) => xs.length > n ? xs.sublist(xs.length - n) : xs;

WorktreeRef _ref(WorkerWorktree wt) => WorktreeRef(path: wt.path, branch: wt.branch, base: wt.base);

/// Writes a file owner-only, whole: to `<file>.tmp`, then renamed over it.
void _writePrivate(String file, String data) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(data, flush: true);
  chmodSync(tmp, 0x180); // 0600
  File(tmp).renameSync(file);
}

/// Where a Codex worker's sessions are logged, for reading its usage.
String _codexHome(String cwd, Map<String, String> env) {
  final configured = env['CODEX_HOME'];
  final home = configured != null && configured.isNotEmpty
      ? configured
      : p.join(env['HOME'] ?? Platform.environment['HOME'] ?? '', '.codex');
  return p.normalize(p.join(p.absolute(cwd), home));
}

/// [args] without any `--model`/`-m` option, for an OpenCode launch that picks its own model (or
/// resumes a session, which keeps the one it had).
List<String> withoutOpenCodeModel(List<String> args) {
  final clean = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--model' || arg == '-m') {
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) i++;
      continue;
    }
    if (arg.startsWith('--model=') || (arg.startsWith('-m') && arg.length > 2)) continue;
    clean.add(arg);
  }
  return clean;
}

/// The office's environment (or [base]), minus anything that would make a child think it's a nested session.
Map<String, String> childEnv([Map<String, String>? base]) => {
  for (final e in (base ?? Platform.environment).entries)
    if (!_scrubbed(e.key)) e.key: e.value,
};

WorkerTask? _validTask(Object? t) => t is Map && t['name'] is String && t['summary'] is String
    ? WorkerTask(name: t['name'] as String, summary: t['summary'] as String)
    : null;

OpenCodeStatusEvent? _openCodeEvent(Object? v) {
  if (v is! Map) return null;
  final type = v['type'], sessionId = v['sessionId'];
  final status = OpenCodeHookStatus.tryParse(v['status']);
  if (type is! String || !OpenCodeStatusEvent.types.contains(type)) return null;
  if (sessionId is! String || sessionId.isEmpty || status == null || v['status'] is! String) return null;
  for (final k in ['prompt', 'tool', 'detail']) {
    if (v[k] != null && v[k] is! String) return null;
  }
  return OpenCodeStatusEvent(
    type: type,
    sessionId: sessionId,
    status: status,
    prompt: v['prompt'] as String?,
    tool: v['tool'] as String?,
    detail: v['detail'] as String?,
  );
}

/// First-run screens Claude shows before it can take a prompt.
final _setupPrompt = RegExp(
  r'trust this folder|Do you trust the files|Select login method|Choose the text style|Press Enter to continue|Bypass Permissions mode',
  caseSensitive: false,
);
final _notLoggedIn = RegExp(r'Not logged in\s*·\s*Run /login|Invalid API key|Please run /login', caseSensitive: false);

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

String _describeTool(Map payload) {
  final name = payload['tool_name'] ?? 'tool';
  final input = payload['tool_input'];
  Object? field(String k) => input is Map ? input[k] : null;
  final detail =
      field('command') ?? field('file_path') ?? field('pattern') ?? field('url') ?? field('description') ?? '';
  final hasDetail = detail is String ? detail.isNotEmpty : detail != false && detail != 0;
  return _truncate(hasDetail ? '$name: $detail' : '$name', 80);
}

String _offlineBanner(_Info info) {
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
({String title, String body}) _draftPr(_Info info, List<String> commits, String by) {
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
