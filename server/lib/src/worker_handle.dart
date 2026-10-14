// What the workers' modules and the provider adapters (providers/) share: a worker's info as it
// changes, and the narrow handle an adapter is given on one worker (see WorkerHandle). Ported from
// upstream's src/server/workers/types.ts.

import 'package:office_shared/shared.dart';

import 'usage.dart';

/// A worker's [WorkerInfo], as it changes. The wire type is immutable; this is copied into one for
/// every update ([view]).
class LiveInfo {
  LiveInfo({
    required this.id,
    required this.kind,
    this.provider,
    this.model,
    this.effort,
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
    this.meeting,
  });

  final String id;
  final WorkerKind kind;
  final AgentProvider? provider;
  final String? model;
  final AgentEffort? effort;
  final String deskId;
  final String name;
  final String color;
  WorkerStatus status;
  bool acked = true;

  /// When it last went to done or needs_input (ms), so N goes to whoever has waited longest first.
  int? waitingSince;
  final String createdBy;
  final int createdAt;
  final String? prompt;
  WorkerWorktree? worktree;

  /// Its worktree (or workspace) folder is gone, and where its branch still is (see worktrees.dart).
  LostBranch? lost;
  PrRef? pr;
  bool? prOpening;
  String? title;
  String? sessionId;
  int? exitCode;
  int cols = 100;
  int rows = 30;
  List<String> viewers = const [];
  List<String> viewerIds = const [];
  String? activity;

  /// What its latest tool call is, for the worker to act out while it works.
  WorkerAction? action;
  WorkerTask? task;
  Usage? usage;
  LastInput? lastInput;

  /// The meeting it was called to, for a worker at the meeting room's table.
  final String? meeting;

  WorkerInfo get view => WorkerInfo(
    id: id,
    kind: kind,
    provider: provider,
    model: model,
    effort: effort,
    deskId: deskId,
    name: name,
    color: color,
    status: status,
    acked: acked,
    waitingSince: waitingSince,
    createdBy: createdBy,
    createdAt: createdAt,
    prompt: prompt,
    worktree: worktree,
    lost: lost,
    pr: pr,
    prOpening: prOpening,
    title: title,
    sessionId: sessionId,
    exitCode: exitCode,
    cols: cols,
    rows: rows,
    viewers: List.unmodifiable(viewers),
    viewerIds: List.unmodifiable(viewerIds),
    activity: activity,
    action: action,
    task: task,
    usage: usage,
    lastInput: lastInput,
    meeting: meeting,
  );
}

/// One worker, as its provider's adapter sees it: what it is and how it's doing, its provider's own
/// state, and what the adapter may do with it. Narrow on purpose, so an adapter never reaches into
/// the manager.
abstract interface class WorkerHandle {
  LiveInfo get info;

  /// Its provider's own state on it (see ProviderAdapter.createState).
  Object? get state;

  /// Its process is running (in a terminal, or over ACP).
  bool get running;

  /// Stuck on a trust, login or first-run screen, rather than asking anything.
  abstract bool bootBlocked;

  /// When it last stopped needing input: a permission prompt right after that is a late one for what was just answered.
  abstract int leftNeedsInputAt;

  /// Test runs and builds that have failed in a row (see failsToDespair).
  abstract int failStreak;

  /// Where its session's tokens and cost are read from (see usage.dart).
  UsageTracker get tracker;

  /// A prompt its start couldn't pass on the command line: typed into its session once that's up.
  abstract String? pendingPrompt;

  /// Moves it to [status], raising its flag as that goes.
  void setStatus(WorkerStatus status);

  /// Tells everyone how it's doing now.
  void emit();

  /// Saves every worker (workers.json).
  void persist();

  /// A new message for it: shown right away, and its task (re)named.
  void notePrompt(String prompt);

  /// A tool call it made, for naming its task.
  void noteTool(String tool);

  /// A new conversation, so a new task.
  void clearTask();

  /// Reads its usage again in a moment (hooks come in bursts).
  void scheduleScan();

  /// Types a prompt into its session; says what went wrong, if anything.
  String? prompt(String text);
}

/// Shortens [s] to one line of at most [n] characters.
String truncateLine(String s, int n) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > n ? '${one.substring(0, n - 1)}…' : one;
}
