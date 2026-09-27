// Wire protocol between browser and server. Every WebSocket frame is one JSON object.
//
// Hand-written port of src/shared/protocol.ts. Readers are tolerant: a missing optional field reads
// as null, a missing required one as a sensible default, an unknown enum value as a fallback, and an
// unknown message type as [UnknownMsg]. Writers omit null fields, the way JSON.stringify drops
// undefined ones.

import 'avatar.dart';
import 'decor.dart';
import 'dog.dart';
import 'json_util.dart';
import 'jukebox.dart';
import 'whiteboard.dart';

export 'json_util.dart' show WireEnum;

// ---- Enums --------------------------------------------------------------------------------------

enum WorkerStatus implements WireEnum {
  /// PTY launched, agent booting.
  starting('starting'),

  /// Waiting for a first prompt.
  idle('idle'),

  /// Agent is busy.
  working('working'),

  /// Permission prompt / question open.
  needsInput('needs_input'),

  /// Finished its turn.
  done('done'),

  /// Process ended (can be resumed if it had a session).
  exited('exited'),

  /// Restored from disk after a server restart; resumable.
  offline('offline');

  const WorkerStatus(this.wire);
  @override
  final String wire;

  static WorkerStatus parse(Object? v) => parseWire(values, v, WorkerStatus.idle);
}

enum WorkerKind implements WireEnum {
  agent('agent'),
  shell('shell');

  const WorkerKind(this.wire);
  @override
  final String wire;

  static WorkerKind parse(Object? v) => parseWire(values, v, WorkerKind.agent);
  static WorkerKind? tryParse(Object? v) => parseWireOrNull(values, v);
}

enum AgentProvider implements WireEnum {
  claude('claude'),
  opencode('opencode'),
  codex('codex'),
  custom('custom');

  const AgentProvider(this.wire);
  @override
  final String wire;

  static AgentProvider parse(Object? v) => parseWire(values, v, AgentProvider.claude);
  static AgentProvider? tryParse(Object? v) => parseWireOrNull(values, v);
}

bool isAgentProvider(Object? value) => AgentProvider.tryParse(value) != null;

/// What becomes of a worker's git worktree when it is sent home.
enum WorktreeCleanup implements WireEnum {
  keep('keep'),
  worktree('worktree'),
  all('all');

  const WorktreeCleanup(this.wire);
  @override
  final String wire;

  static WorktreeCleanup parse(Object? v) => parseWire(values, v, WorktreeCleanup.keep);
}

/// A pull request's checks, rolled up for its board card.
enum GhChecks implements WireEnum {
  pass('pass'),
  fail('fail'),
  pending('pending'),
  none('none');

  const GhChecks(this.wire);
  @override
  final String wire;

  static GhChecks parse(Object? v) => parseWire(values, v, GhChecks.none);
}

enum TaskStatus implements WireEnum {
  queued('queued'),
  running('running'),
  done('done');

  const TaskStatus(this.wire);
  @override
  final String wire;

  static TaskStatus parse(Object? v) => parseWire(values, v, TaskStatus.queued);
}

/// How a queued task ended: the worker finished its turn, stopped or fell asleep, was sent home, or never started.
enum TaskOutcome implements WireEnum {
  done('done'),
  exited('exited'),
  killed('killed'),
  failed('failed');

  const TaskOutcome(this.wire);
  @override
  final String wire;

  static TaskOutcome? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// Where a team webhook posts: Slack and Discord get their own message format, anything else plain JSON.
enum WebhookKind implements WireEnum {
  slack('slack'),
  discord('discord'),
  other('other');

  const WebhookKind(this.wire);
  @override
  final String wire;

  static WebhookKind parse(Object? v) => parseWire(values, v, WebhookKind.other);
}

enum GhMergeMethod implements WireEnum {
  squash('squash'),
  merge('merge'),
  rebase('rebase');

  const GhMergeMethod(this.wire);
  @override
  final String wire;

  static GhMergeMethod parse(Object? v) => parseWire(values, v, GhMergeMethod.squash);
}

/// Why an issue was closed, as GitHub records it.
enum GhCloseReason implements WireEnum {
  completed('completed'),
  notPlanned('not planned');

  const GhCloseReason(this.wire);
  @override
  final String wire;

  static GhCloseReason parse(Object? v) => parseWire(values, v, GhCloseReason.completed);
}

/// LEFT is the old file's line numbers, RIGHT the new file's.
enum GhReviewSide implements WireEnum {
  left('LEFT'),
  right('RIGHT');

  const GhReviewSide(this.wire);
  @override
  final String wire;

  static GhReviewSide parse(Object? v) => parseWire(values, v, GhReviewSide.right);
}

enum GhCheckState implements WireEnum {
  pass('pass'),
  fail('fail'),
  pending('pending'),
  skip('skip');

  const GhCheckState(this.wire);
  @override
  final String wire;

  static GhCheckState parse(Object? v) => parseWire(values, v, GhCheckState.pending);
}

/// An issue or a pull request, in the gh.comment / gh.close messages.
enum GhKind implements WireEnum {
  issue('issue'),
  pull('pull');

  const GhKind(this.wire);
  @override
  final String wire;

  static GhKind parse(Object? v) => parseWire(values, v, GhKind.issue);
}

enum AccountRole implements WireEnum {
  admin('admin'),
  member('member');

  const AccountRole(this.wire);
  @override
  final String wire;

  static AccountRole parse(Object? v) => parseWire(values, v, AccountRole.member);
}

/// M modified, A added, D deleted, R renamed, T type changed, ? untracked (new, never committed).
enum ChangeStatus implements WireEnum {
  modified('M'),
  added('A'),
  deleted('D'),
  renamed('R'),
  typeChanged('T'),
  untracked('?');

  const ChangeStatus(this.wire);
  @override
  final String wire;

  static ChangeStatus parse(Object? v) => parseWire(values, v, ChangeStatus.modified);
}

enum UpgradePhase implements WireEnum {
  idle('idle'),
  building('building'),
  restarting('restarting'),
  failed('failed');

  const UpgradePhase(this.wire);
  @override
  final String wire;

  static UpgradePhase parse(Object? v) => parseWire(values, v, UpgradePhase.idle);
}

enum Weather implements WireEnum {
  clear('clear'),
  cloudy('cloudy'),
  rain('rain'),
  storm('storm'),
  snow('snow'),
  fog('fog');

  const Weather(this.wire);
  @override
  final String wire;

  static Weather parse(Object? v) => parseWire(values, v, Weather.clear);
}

const List<Weather> weathers = Weather.values;

/// Why the gong rang.
enum GongWhy implements WireEnum {
  hit('hit'),
  merged('merged'),
  queue('queue');

  const GongWhy(this.wire);
  @override
  final String wire;

  static GongWhy parse(Object? v) => parseWire(values, v, GongWhy.hit);
}

enum ToastLevel implements WireEnum {
  info('info'),
  warn('warn'),
  error('error');

  const ToastLevel(this.wire);
  @override
  final String wire;

  static ToastLevel parse(Object? v) => parseWire(values, v, ToastLevel.info);
}

// ---- Workers ------------------------------------------------------------------------------------

/// Anything that writes itself as a JSON object.
abstract interface class JsonObject {
  Map<String, dynamic> toJson();
}

/// What a worker is on, for the card above its head: "Fix Login Redirect" + what it's doing now.
class WorkerTask implements JsonObject {
  const WorkerTask({required this.name, required this.summary});

  factory WorkerTask.fromJson(Map<String, dynamic> j) => WorkerTask(name: asString(j['name']), summary: asString(j['summary']));

  final String name;
  final String summary;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'summary': summary};
}

/// A worker's own git worktree (path relative to the office dir). `from` is the branch the office
/// was on when the worktree was cut, which its pull request targets.
class WorkerWorktree implements JsonObject {
  const WorkerWorktree({required this.path, required this.branch, required this.base, this.from});

  factory WorkerWorktree.fromJson(Map<String, dynamic> j) =>
      WorkerWorktree(path: asString(j['path']), branch: asString(j['branch']), base: asString(j['base']), from: asStringOrNull(j['from']));

  final String path;
  final String branch;
  final String base;
  final String? from;

  @override
  Map<String, dynamic> toJson() => {'path': path, 'branch': branch, 'base': base, 'from': ?from};
}

/// A pull request: its number and link.
class PrRef implements JsonObject {
  const PrRef({required this.number, required this.url});

  factory PrRef.fromJson(Map<String, dynamic> j) => PrRef(number: asInt(j['number']), url: asString(j['url']));

  final int number;
  final String url;

  @override
  Map<String, dynamic> toJson() => {'number': number, 'url': url};
}

/// Who last typed into a terminal (or sent it a prompt), and when.
class LastInput implements JsonObject {
  const LastInput({required this.by, required this.at});

  factory LastInput.fromJson(Map<String, dynamic> j) => LastInput(by: asString(j['by']), at: asInt(j['at']));

  final String by;
  final int at;

  @override
  Map<String, dynamic> toJson() => {'by': by, 'at': at};
}

class WorkerInfo implements JsonObject {
  const WorkerInfo({
    required this.id,
    required this.kind,
    this.provider,
    this.model,
    required this.deskId,
    required this.name,
    required this.color,
    required this.status,
    required this.acked,
    required this.createdBy,
    required this.createdAt,
    this.prompt,
    this.worktree,
    this.pr,
    this.prOpening,
    this.title,
    this.sessionId,
    this.exitCode,
    required this.cols,
    required this.rows,
    required this.viewers,
    this.activity,
    this.task,
    this.usage,
    this.lastInput,
  });

  factory WorkerInfo.fromJson(Map<String, dynamic> j) => WorkerInfo(
        id: asString(j['id']),
        kind: WorkerKind.parse(j['kind']),
        provider: AgentProvider.tryParse(j['provider']),
        model: asStringOrNull(j['model']),
        deskId: asString(j['deskId']),
        name: asString(j['name']),
        color: asString(j['color'], '#888888'),
        status: WorkerStatus.parse(j['status']),
        acked: asBool(j['acked']),
        createdBy: asString(j['createdBy']),
        createdAt: asInt(j['createdAt']),
        prompt: asStringOrNull(j['prompt']),
        worktree: _obj(j['worktree'], WorkerWorktree.fromJson),
        pr: _obj(j['pr'], PrRef.fromJson),
        prOpening: asBoolOrNull(j['prOpening']),
        title: asStringOrNull(j['title']),
        sessionId: asStringOrNull(j['sessionId']),
        exitCode: asIntOrNull(j['exitCode']),
        cols: asInt(j['cols'], 80),
        rows: asInt(j['rows'], 24),
        viewers: asStringList(j['viewers']),
        activity: asStringOrNull(j['activity']),
        task: _obj(j['task'], WorkerTask.fromJson),
        usage: _obj(j['usage'], Usage.fromJson),
        lastInput: _obj(j['lastInput'], LastInput.fromJson),
      );

  final String id;

  /// 'agent' runs the selected provider; 'shell' is a plain shared login shell.
  final WorkerKind kind;
  final AgentProvider? provider;

  /// Initial OpenCode model selected for this worker, when one was requested.
  final String? model;
  final String deskId;
  final String name;
  final String color;
  final WorkerStatus status;

  /// True once someone opened the terminal after the last done / needs_input.
  final bool acked;
  final String createdBy;
  final int createdAt;
  final String? prompt;

  /// Set when the worker runs in its own git worktree.
  final WorkerWorktree? worktree;

  /// The pull request opened from this desk for the worktree branch (see 'worker.pr').
  final PrRef? pr;

  /// True while the branch is being pushed and its pull request opened.
  final bool? prOpening;
  final String? title;
  final String? sessionId;
  final int? exitCode;
  final int cols;
  final int rows;

  /// Names of people currently viewing the terminal.
  final List<String> viewers;

  /// Latest line of meaningful activity (e.g. last prompt or tool).
  final String? activity;

  /// Written by a small model from its prompts and recent tool calls (see server/tasks.ts).
  final WorkerTask? task;

  /// Reported session tokens and cost, when the provider supplies them (agents only).
  final Usage? usage;

  /// Who last typed into its terminal (or sent it a prompt), and when.
  final LastInput? lastInput;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.wire,
        'provider': ?provider?.wire,
        'model': ?model,
        'deskId': deskId,
        'name': name,
        'color': color,
        'status': status.wire,
        'acked': acked,
        'createdBy': createdBy,
        'createdAt': createdAt,
        'prompt': ?prompt,
        'worktree': ?worktree?.toJson(),
        'pr': ?pr?.toJson(),
        'prOpening': ?prOpening,
        'title': ?title,
        'sessionId': ?sessionId,
        'exitCode': ?exitCode,
        'cols': cols,
        'rows': rows,
        'viewers': viewers,
        'activity': ?activity,
        'task': ?task?.toJson(),
        'usage': ?usage?.toJson(),
        'lastInput': ?lastInput?.toJson(),
      };
}

/// Session usage. The persistent office ledger continues to cover Claude Code only.
class Usage implements JsonObject {
  const Usage({
    required this.input,
    required this.output,
    this.reasoning,
    this.costKnown,
    this.incomplete,
    required this.cacheWrite,
    required this.cacheRead,
    required this.cost,
    required this.calls,
    this.callsKnown,
    this.totalTokens,
  });

  static const Usage zero = Usage(input: 0, output: 0, cacheWrite: 0, cacheRead: 0, cost: 0, calls: 0);

  factory Usage.fromJson(Map<String, dynamic> j) => Usage(
        input: asInt(j['input']),
        output: asInt(j['output']),
        reasoning: asIntOrNull(j['reasoning']),
        costKnown: asBoolOrNull(j['costKnown']),
        incomplete: asBoolOrNull(j['incomplete']),
        cacheWrite: asInt(j['cacheWrite']),
        cacheRead: asInt(j['cacheRead']),
        cost: asDouble(j['cost']),
        calls: asInt(j['calls']),
        callsKnown: asBoolOrNull(j['callsKnown']),
        totalTokens: asIntOrNull(j['totalTokens']),
      );

  /// Input tokens that missed the prompt cache.
  final int input;
  final int output;

  /// Reasoning tokens reported separately from output, when available.
  final int? reasoning;

  /// False when the provider supplies tokens without usable pricing. Omitted for legacy Claude usage.
  final bool? costKnown;

  /// Provider history is still loading, failed to load, or reached a traversal limit.
  final bool? incomplete;

  /// Tokens written to the prompt cache.
  final int cacheWrite;

  /// Tokens read from the prompt cache.
  final int cacheRead;

  /// USD: estimated from the office's price list while a session runs, Claude Code's own figure once it has ended.
  final double cost;

  /// API calls (assistant messages) counted.
  final int calls;

  /// False when the provider reports cumulative tokens without a reliable call count.
  final bool? callsKnown;

  /// Authoritative provider total when it cannot be reconstructed from the displayed buckets.
  final int? totalTokens;

  @override
  Map<String, dynamic> toJson() => {
        'input': input,
        'output': output,
        'reasoning': ?reasoning,
        'costKnown': ?costKnown,
        'incomplete': ?incomplete,
        'cacheWrite': cacheWrite,
        'cacheRead': cacheRead,
        'cost': cost,
        'calls': calls,
        'callsKnown': ?callsKnown,
        'totalTokens': ?totalTokens,
      };
}

/// Spend across the whole office, kept on disk (see server/usage.ts).
class UsageState implements JsonObject {
  const UsageState({required this.total, required this.today, required this.day, this.budget, required this.pauseHiring});

  factory UsageState.fromJson(Map<String, dynamic> j) => UsageState(
        total: _obj(j['total'], Usage.fromJson) ?? Usage.zero,
        today: _obj(j['today'], Usage.fromJson) ?? Usage.zero,
        day: asString(j['day']),
        budget: asDoubleOrNull(j['budget']),
        pauseHiring: asBool(j['pauseHiring']),
      );

  /// Every worker the office ever ran, including ones sent home.
  final Usage total;

  /// Since midnight on the office's machine.
  final Usage today;

  /// The day `today` covers, YYYY-MM-DD on the office's machine.
  final String day;

  /// Daily budget in USD (--budget), when one is set.
  final double? budget;

  /// New hires are refused for the rest of the day once the budget is spent (--budget-pause).
  final bool pauseHiring;

  @override
  Map<String, dynamic> toJson() => {'total': total.toJson(), 'today': today.toJson(), 'day': day, 'budget': ?budget, 'pauseHiring': pauseHiring};
}

/// One of the Claude plan's usage windows: the 5-hour session, the week, or a model's week.
class PlanWindow implements JsonObject {
  const PlanWindow({required this.label, required this.pct, this.resetsAt});

  factory PlanWindow.fromJson(Map<String, dynamic> j) => PlanWindow(label: asString(j['label']), pct: asDouble(j['pct']), resetsAt: asIntOrNull(j['resetsAt']));

  /// e.g. "5h session", "Week", "Fable week".
  final String label;

  /// Percent of the window used, 0-100.
  final double pct;

  /// When it starts over (ms since epoch), when known.
  final int? resetsAt;

  @override
  Map<String, dynamic> toJson() => {'label': label, 'pct': pct, 'resetsAt': ?resetsAt};
}

/// The Claude plan limits of the account the office's Claude workers run on, as Claude Code's
/// /usage shows them (see server/limits.ts). One account for the whole building.
class PlanLimits implements JsonObject {
  const PlanLimits({this.plan, required this.windows, required this.at});

  factory PlanLimits.fromJson(Map<String, dynamic> j) => PlanLimits(plan: asStringOrNull(j['plan']), windows: asList(j['windows'], PlanWindow.fromJson), at: asInt(j['at']));

  /// 'pro', 'max', 'team', 'enterprise'…, when known.
  final String? plan;

  /// The 5-hour session first, then the week, then per-model weeks. Empty until first read, or when there is no plan.
  final List<PlanWindow> windows;

  /// When the numbers were read (ms since epoch); 0 before the first read.
  final int at;

  @override
  Map<String, dynamic> toJson() => {'plan': ?plan, 'windows': _list(windows), 'at': at};
}

/// What a worker's worktree holds, so whoever sends it home knows what deleting it would lose.
class WorktreeState implements JsonObject {
  const WorktreeState({required this.exists, required this.dirty, required this.ahead, required this.unpushed, this.error});

  factory WorktreeState.fromJson(Map<String, dynamic> j) => WorktreeState(
        exists: asBool(j['exists']),
        dirty: asInt(j['dirty']),
        ahead: asInt(j['ahead']),
        unpushed: asInt(j['unpushed']),
        error: asStringOrNull(j['error']),
      );

  /// The worktree folder is still there.
  final bool exists;

  /// Files with uncommitted changes, new ones included.
  final int dirty;

  /// Commits on its branch since it was made.
  final int ahead;

  /// Commits only its branch has: on no remote, and not in the office's own checkout.
  final int unpushed;

  /// Set when git couldn't tell, e.g. the branch is gone.
  final String? error;

  @override
  Map<String, dynamic> toJson() => {'exists': exists, 'dirty': dirty, 'ahead': ahead, 'unpushed': unpushed, 'error': ?error};
}

// ---- People -------------------------------------------------------------------------------------

class PeerInfo implements JsonObject {
  const PeerInfo({
    required this.id,
    required this.name,
    required this.color,
    required this.look,
    required this.x,
    required this.y,
    required this.z,
    required this.rotY,
    required this.moving,
    required this.voice,
    required this.muted,
    required this.sharing,
    this.smoking,
    this.seat,
    this.account,
    this.floor,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
        id: asString(j['id']),
        name: asString(j['name']),
        color: asString(j['color'], '#888888'),
        look: Look.fromJson(j['look']),
        x: asDouble(j['x']),
        y: asDouble(j['y']),
        z: asDouble(j['z']),
        rotY: asDouble(j['rotY']),
        moving: asBool(j['moving']),
        voice: asBool(j['voice']),
        muted: asBool(j['muted']),
        sharing: asBool(j['sharing']),
        smoking: asBoolOrNull(j['smoking']),
        seat: asStringOrNull(j['seat']),
        account: asBoolOrNull(j['account']),
        floor: asStringOrNull(j['floor']),
      );

  final String id;
  final String name;
  final String color;

  /// Skin tone and hair, picked on the character select screen.
  final Look look;
  final double x;
  final double y;
  final double z;
  final double rotY;
  final bool moving;
  final bool voice;
  final bool muted;
  final bool sharing;

  /// On a smoke break, cigarette in hand.
  final bool? smoking;

  /// Sitting down: the place they're in (see seatAt in layout), like "couch:1".
  final String? seat;

  /// Signed in with their own account, so `name` is theirs and nobody else can take it.
  final bool? account;

  /// The floor they're on (see FloorInfo); none while the building has no floors yet.
  final String? floor;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'look': look.toJson(),
        'x': x,
        'y': y,
        'z': z,
        'rotY': rotY,
        'moving': moving,
        'voice': voice,
        'muted': muted,
        'sharing': sharing,
        'smoking': ?smoking,
        'seat': ?seat,
        'account': ?account,
        'floor': ?floor,
      };
}

// ---- Terminal screens ---------------------------------------------------------------------------

/// Color encoding: -1 default, 0..255 palette, >= 0x1000000 means 0x1000000 | rgb.
const int rgbFlag = 0x1000000;
const int flagBold = 1;
const int flagInverse = 2;
const int flagDim = 4;

/// A styled run of text on a terminal row: [text, fg, bg, flags] on the wire.
class Run {
  const Run(this.text, this.fg, this.bg, this.flags);

  factory Run.fromJson(Object? v) {
    if (v is! List) return const Run('', -1, -1, 0);
    return Run(v.isNotEmpty ? asString(v[0]) : '', v.length > 1 ? asInt(v[1], -1) : -1, v.length > 2 ? asInt(v[2], -1) : -1, v.length > 3 ? asInt(v[3]) : 0);
  }

  final String text;

  /// -1 default, 0..255 palette, or [rgbFlag] | 0xRRGGBB.
  final int fg;
  final int bg;

  /// [flagBold] | [flagInverse] | [flagDim].
  final int flags;

  bool get bold => flags & flagBold != 0;
  bool get inverse => flags & flagInverse != 0;
  bool get dim => flags & flagDim != 0;

  List<Object> toJson() => [text, fg, bg, flags];

  @override
  bool operator ==(Object other) => other is Run && other.text == text && other.fg == fg && other.bg == bg && other.flags == flags;

  @override
  int get hashCode => Object.hash(text, fg, bg, flags);
}

// ---- GitHub -------------------------------------------------------------------------------------

class GhLabel implements JsonObject {
  const GhLabel({required this.name, required this.color});

  factory GhLabel.fromJson(Map<String, dynamic> j) => GhLabel(name: asString(j['name']), color: asString(j['color']));

  final String name;

  /// Hex without '#', as GitHub gives it.
  final String color;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'color': color};
}

class GhIssue implements JsonObject {
  const GhIssue({
    required this.number,
    required this.title,
    required this.state,
    required this.url,
    required this.author,
    required this.labels,
    required this.assignees,
    required this.createdAt,
    required this.updatedAt,
    required this.body,
    required this.comments,
  });

  factory GhIssue.fromJson(Map<String, dynamic> j) => GhIssue(
        number: asInt(j['number']),
        title: asString(j['title']),
        state: asString(j['state']),
        url: asString(j['url']),
        author: asString(j['author']),
        labels: asList(j['labels'], GhLabel.fromJson),
        assignees: asStringList(j['assignees']),
        createdAt: asString(j['createdAt']),
        updatedAt: asString(j['updatedAt']),
        body: asString(j['body']),
        comments: asInt(j['comments']),
      );

  final int number;
  final String title;
  final String state;
  final String url;
  final String author;
  final List<GhLabel> labels;
  final List<String> assignees;
  final String createdAt;
  final String updatedAt;
  final String body;
  final int comments;

  @override
  Map<String, dynamic> toJson() => {
        'number': number,
        'title': title,
        'state': state,
        'url': url,
        'author': author,
        'labels': _list(labels),
        'assignees': assignees,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'body': body,
        'comments': comments,
      };
}

class GhPull implements JsonObject {
  const GhPull({
    required this.number,
    required this.title,
    required this.state,
    required this.isDraft,
    required this.url,
    required this.author,
    required this.labels,
    required this.reviewDecision,
    required this.headRefName,
    required this.baseRefName,
    required this.createdAt,
    required this.updatedAt,
    required this.additions,
    required this.deletions,
    required this.checks,
    required this.body,
    required this.closes,
  });

  factory GhPull.fromJson(Map<String, dynamic> j) => GhPull(
        number: asInt(j['number']),
        title: asString(j['title']),
        state: asString(j['state']),
        isDraft: asBool(j['isDraft']),
        url: asString(j['url']),
        author: asString(j['author']),
        labels: asList(j['labels'], GhLabel.fromJson),
        reviewDecision: asString(j['reviewDecision']),
        headRefName: asString(j['headRefName']),
        baseRefName: asString(j['baseRefName']),
        createdAt: asString(j['createdAt']),
        updatedAt: asString(j['updatedAt']),
        additions: asInt(j['additions']),
        deletions: asInt(j['deletions']),
        checks: GhChecks.parse(j['checks']),
        body: asString(j['body']),
        closes: asIntList(j['closes']),
      );

  final int number;
  final String title;
  final String state;
  final bool isDraft;
  final String url;
  final String author;
  final List<GhLabel> labels;
  final String reviewDecision;
  final String headRefName;
  final String baseRefName;
  final String createdAt;
  final String updatedAt;
  final int additions;
  final int deletions;
  final GhChecks checks;
  final String body;

  /// Issues it closes ("closes #12" in its description), as GitHub links them.
  final List<int> closes;

  @override
  Map<String, dynamic> toJson() => {
        'number': number,
        'title': title,
        'state': state,
        'isDraft': isDraft,
        'url': url,
        'author': author,
        'labels': _list(labels),
        'reviewDecision': reviewDecision,
        'headRefName': headRefName,
        'baseRefName': baseRefName,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'additions': additions,
        'deletions': deletions,
        'checks': checks.wire,
        'body': body,
        'closes': closes,
      };
}

class GhState<T extends JsonObject> implements JsonObject {
  const GhState({required this.items, this.error, required this.fetchedAt, required this.loading});

  factory GhState.fromJson(Map<String, dynamic> j, T Function(Map<String, dynamic>) read) => GhState(
        items: asList(j['items'], read),
        error: asStringOrNull(j['error']),
        fetchedAt: asInt(j['fetchedAt']),
        loading: asBool(j['loading']),
      );

  final List<T> items;
  final String? error;
  final int fetchedAt;
  final bool loading;

  @override
  Map<String, dynamic> toJson() => {'items': _list(items), 'error': ?error, 'fetchedAt': fetchedAt, 'loading': loading};
}

/// How the repository lets pull requests be merged.
class GhRepoInfo implements JsonObject {
  const GhRepoInfo({required this.nameWithOwner, required this.methods});

  factory GhRepoInfo.fromJson(Map<String, dynamic> j) => GhRepoInfo(
        nameWithOwner: asString(j['nameWithOwner']),
        methods: [for (final m in asStringList(j['methods'])) ?parseWireOrNull(GhMergeMethod.values, m)],
      );

  final String nameWithOwner;
  final List<GhMergeMethod> methods;

  @override
  Map<String, dynamic> toJson() => {'nameWithOwner': nameWithOwner, 'methods': [for (final m in methods) m.wire]};
}

/// A comment on an issue or on a PR's conversation, or a submitted review.
class GhComment implements JsonObject {
  const GhComment({required this.id, required this.author, required this.body, required this.createdAt, this.url, this.state});

  factory GhComment.fromJson(Map<String, dynamic> j) => GhComment(
        id: asString(j['id']),
        author: asString(j['author']),
        body: asString(j['body']),
        createdAt: asString(j['createdAt']),
        url: asStringOrNull(j['url']),
        state: asStringOrNull(j['state']),
      );

  final String id;
  final String author;
  final String body;
  final String createdAt;
  final String? url;

  /// Reviews only: APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED.
  final String? state;

  @override
  Map<String, dynamic> toJson() => {'id': id, 'author': author, 'body': body, 'createdAt': createdAt, 'url': ?url, 'state': ?state};
}

/// A comment on a line of a PR's diff.
class GhReviewComment implements JsonObject {
  const GhReviewComment({
    required this.id,
    this.replyTo,
    required this.author,
    required this.body,
    required this.createdAt,
    required this.url,
    required this.path,
    required this.line,
    required this.side,
  });

  factory GhReviewComment.fromJson(Map<String, dynamic> j) => GhReviewComment(
        id: asInt(j['id']),
        replyTo: asIntOrNull(j['replyTo']),
        author: asString(j['author']),
        body: asString(j['body']),
        createdAt: asString(j['createdAt']),
        url: asString(j['url']),
        path: asString(j['path']),
        line: asIntOrNull(j['line']),
        side: GhReviewSide.parse(j['side']),
      );

  final int id;

  /// The first comment of the thread this one answers.
  final int? replyTo;
  final String author;
  final String body;
  final String createdAt;
  final String url;
  final String path;

  /// The line it's on now, or null when the code under it changed since (outdated). Always sent, as null.
  final int? line;
  final GhReviewSide side;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'replyTo': ?replyTo,
        'author': author,
        'body': body,
        'createdAt': createdAt,
        'url': url,
        'path': path,
        'line': line,
        'side': side.wire,
      };
}

class GhCheck implements JsonObject {
  const GhCheck({required this.name, required this.state, this.url});

  factory GhCheck.fromJson(Map<String, dynamic> j) => GhCheck(name: asString(j['name']), state: GhCheckState.parse(j['state']), url: asStringOrNull(j['url']));

  final String name;
  final GhCheckState state;
  final String? url;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'state': state.wire, 'url': ?url};
}

/// Everything the PR window shows beyond the board card: GET /api/gh/pull?number=N
class GhPullDetail implements JsonObject {
  const GhPullDetail({
    required this.number,
    required this.body,
    required this.state,
    required this.isDraft,
    required this.reviewDecision,
    required this.headRefName,
    required this.baseRefName,
    required this.mergeable,
    required this.mergeStateStatus,
    required this.commits,
    required this.comments,
    required this.reviews,
    required this.reviewComments,
    required this.checks,
    required this.repo,
    required this.viewer,
  });

  factory GhPullDetail.fromJson(Map<String, dynamic> j) => GhPullDetail(
        number: asInt(j['number']),
        body: asString(j['body']),
        state: asString(j['state']),
        isDraft: asBool(j['isDraft']),
        reviewDecision: asString(j['reviewDecision']),
        headRefName: asString(j['headRefName']),
        baseRefName: asString(j['baseRefName']),
        mergeable: asString(j['mergeable'], 'UNKNOWN'),
        mergeStateStatus: asString(j['mergeStateStatus'], 'UNKNOWN'),
        commits: asInt(j['commits']),
        comments: asList(j['comments'], GhComment.fromJson),
        reviews: asList(j['reviews'], GhComment.fromJson),
        reviewComments: asList(j['reviewComments'], GhReviewComment.fromJson),
        checks: asList(j['checks'], GhCheck.fromJson),
        repo: GhRepoInfo.fromJson(asMap(j['repo'])),
        viewer: asString(j['viewer']),
      );

  final int number;
  final String body;
  final String state;
  final bool isDraft;
  final String reviewDecision;
  final String headRefName;
  final String baseRefName;

  /// MERGEABLE, CONFLICTING or UNKNOWN (GitHub still working it out).
  final String mergeable;

  /// CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, DRAFT, HAS_HOOKS or UNKNOWN.
  final String mergeStateStatus;
  final int commits;
  final List<GhComment> comments;
  final List<GhComment> reviews;
  final List<GhReviewComment> reviewComments;
  final List<GhCheck> checks;
  final GhRepoInfo repo;

  /// Who gh is signed in as on the server, and so who comments from the office appear from ('' if unknown).
  final String viewer;

  @override
  Map<String, dynamic> toJson() => {
        'number': number,
        'body': body,
        'state': state,
        'isDraft': isDraft,
        'reviewDecision': reviewDecision,
        'headRefName': headRefName,
        'baseRefName': baseRefName,
        'mergeable': mergeable,
        'mergeStateStatus': mergeStateStatus,
        'commits': commits,
        'comments': _list(comments),
        'reviews': _list(reviews),
        'reviewComments': _list(reviewComments),
        'checks': _list(checks),
        'repo': repo.toJson(),
        'viewer': viewer,
      };
}

/// GET /api/gh/issue?number=N
class GhIssueDetail implements JsonObject {
  const GhIssueDetail({required this.number, required this.state, required this.body, required this.comments, required this.viewer});

  factory GhIssueDetail.fromJson(Map<String, dynamic> j) => GhIssueDetail(
        number: asInt(j['number']),
        state: asString(j['state']),
        body: asString(j['body']),
        comments: asList(j['comments'], GhComment.fromJson),
        viewer: asString(j['viewer']),
      );

  final int number;

  /// OPEN or CLOSED.
  final String state;
  final String body;
  final List<GhComment> comments;

  /// See [GhPullDetail.viewer].
  final String viewer;

  @override
  Map<String, dynamic> toJson() => {'number': number, 'state': state, 'body': body, 'comments': _list(comments), 'viewer': viewer};
}

/// GitHub turns away comments longer than this.
const int ghCommentMax = 65536;

// ---- The task queue -----------------------------------------------------------------------------

/// The pull request that closes a queued task's issue, or was opened from the worker's branch.
class QueueTaskPr implements JsonObject {
  const QueueTaskPr({required this.number, required this.url, required this.state, required this.title});

  factory QueueTaskPr.fromJson(Map<String, dynamic> j) =>
      QueueTaskPr(number: asInt(j['number']), url: asString(j['url']), state: asString(j['state']), title: asString(j['title']));

  final int number;
  final String url;
  final String state;
  final String title;

  @override
  Map<String, dynamic> toJson() => {'number': number, 'url': url, 'state': state, 'title': title};
}

/// A task on the 📋 queue whiteboard: a GitHub issue or free text, seated to a worker by itself.
class QueueTask implements JsonObject {
  const QueueTask({
    required this.id,
    this.provider,
    this.model,
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

  factory QueueTask.fromJson(Map<String, dynamic> j) => QueueTask(
        id: asString(j['id']),
        provider: AgentProvider.tryParse(j['provider']),
        model: asStringOrNull(j['model']),
        issue: asIntOrNull(j['issue']),
        title: asString(j['title']),
        prompt: asString(j['prompt']),
        addedBy: asString(j['addedBy']),
        addedAt: asInt(j['addedAt']),
        status: TaskStatus.parse(j['status']),
        workerId: asStringOrNull(j['workerId']),
        workerName: asStringOrNull(j['workerName']),
        branch: asStringOrNull(j['branch']),
        startedAt: asIntOrNull(j['startedAt']),
        finishedAt: asIntOrNull(j['finishedAt']),
        outcome: TaskOutcome.tryParse(j['outcome']),
        error: asStringOrNull(j['error']),
        pr: _obj(j['pr'], QueueTaskPr.fromJson),
      );

  final String id;
  final AgentProvider? provider;

  /// Initial OpenCode model selected for this task, when one was requested.
  final String? model;

  /// The GitHub issue it came from, when it did.
  final int? issue;
  final String title;
  final String prompt;
  final String addedBy;
  final int addedAt;
  final TaskStatus status;

  /// The worker seated for it (it may have gone home since).
  final String? workerId;
  final String? workerName;

  /// The worker's own branch, when it got a worktree.
  final String? branch;
  final int? startedAt;
  final int? finishedAt;

  /// How it ended: the worker finished its turn, stopped or fell asleep, was sent home, or never started.
  final TaskOutcome? outcome;
  final String? error;

  /// The pull request that closes the issue, or was opened from the worker's branch.
  final QueueTaskPr? pr;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': ?provider?.wire,
        'model': ?model,
        'issue': ?issue,
        'title': title,
        'prompt': prompt,
        'addedBy': addedBy,
        'addedAt': addedAt,
        'status': status.wire,
        'workerId': ?workerId,
        'workerName': ?workerName,
        'branch': ?branch,
        'startedAt': ?startedAt,
        'finishedAt': ?finishedAt,
        'outcome': ?outcome?.wire,
        'error': ?error,
        'pr': ?pr?.toJson(),
      };
}

class QueueState implements JsonObject {
  const QueueState({required this.tasks, required this.maxWorkers});

  factory QueueState.fromJson(Map<String, dynamic> j) => QueueState(tasks: asList(j['tasks'], QueueTask.fromJson), maxWorkers: asInt(j['maxWorkers']));

  final List<QueueTask> tasks;

  /// How many workers the queue may keep busy at once; 0 pauses it.
  final int maxWorkers;

  @override
  Map<String, dynamic> toJson() => {'tasks': _list(tasks), 'maxWorkers': maxWorkers};
}

// ---- Notifications ------------------------------------------------------------------------------

/// Never the webhook URL itself (it lets anyone post to the channel): just where it goes.
class NotifyWebhook implements JsonObject {
  const NotifyWebhook({required this.kind, required this.hint, required this.by, required this.at});

  factory NotifyWebhook.fromJson(Map<String, dynamic> j) =>
      NotifyWebhook(kind: WebhookKind.parse(j['kind']), hint: asString(j['hint']), by: asString(j['by']), at: asInt(j['at']));

  final WebhookKind kind;
  final String hint;
  final String by;
  final int at;

  @override
  Map<String, dynamic> toJson() => {'kind': kind.wire, 'hint': hint, 'by': by, 'at': at};
}

/// The office's Slack / Discord webhook, pinged when a worker needs input or finishes (see server/webhook.ts).
class NotifyState implements JsonObject {
  const NotifyState({this.webhook, this.error, this.lastSentAt});

  factory NotifyState.fromJson(Map<String, dynamic> j) =>
      NotifyState(webhook: _obj(j['webhook'], NotifyWebhook.fromJson), error: asStringOrNull(j['error']), lastSentAt: asIntOrNull(j['lastSentAt']));

  final NotifyWebhook? webhook;

  /// Why the last post failed, until one gets through.
  final String? error;
  final int? lastSentAt;

  @override
  Map<String, dynamic> toJson() => {'webhook': ?webhook?.toJson(), 'error': ?error, 'lastSentAt': ?lastSentAt};
}

// ---- Floors -------------------------------------------------------------------------------------

class ProjectInfo implements JsonObject {
  const ProjectInfo({required this.name, required this.dir, this.branch, this.remote, required this.agentCmd, required this.defaultProvider, required this.agentProviders});

  factory ProjectInfo.fromJson(Map<String, dynamic> j) => ProjectInfo(
        name: asString(j['name']),
        dir: asString(j['dir']),
        branch: asStringOrNull(j['branch']),
        remote: asStringOrNull(j['remote']),
        agentCmd: asString(j['agentCmd']),
        defaultProvider: AgentProvider.parse(j['defaultProvider']),
        agentProviders: [for (final p in asStringList(j['agentProviders'])) ?AgentProvider.tryParse(p)],
      );

  final String name;
  final String dir;
  final String? branch;
  final String? remote;
  final String agentCmd;
  final AgentProvider defaultProvider;
  final List<AgentProvider> agentProviders;

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'dir': dir,
        'branch': ?branch,
        'remote': ?remote,
        'agentCmd': agentCmd,
        'defaultProvider': defaultProvider.wire,
        'agentProviders': [for (final p in agentProviders) p.wire],
      };
}

/// One floor of the building: a project in its own checkout, with its own desks, workers, boards
/// and queue. You go between them in the elevator.
class FloorInfo implements JsonObject {
  const FloorInfo({
    required this.id,
    required this.name,
    this.repo,
    required this.dir,
    required this.palette,
    this.cloning,
    required this.addedBy,
    required this.addedAt,
    required this.workers,
    required this.busy,
    required this.waiting,
    required this.people,
  });

  factory FloorInfo.fromJson(Map<String, dynamic> j) => FloorInfo(
        id: asString(j['id']),
        name: asString(j['name']),
        repo: asStringOrNull(j['repo']),
        dir: asString(j['dir']),
        palette: asInt(j['palette']),
        cloning: asBoolOrNull(j['cloning']),
        addedBy: asString(j['addedBy']),
        addedAt: asInt(j['addedAt']),
        workers: asInt(j['workers']),
        busy: asInt(j['busy']),
        waiting: asInt(j['waiting']),
        people: asInt(j['people']),
      );

  final String id;

  /// The repository's name, or the folder's when it isn't on GitHub.
  final String name;

  /// owner/name on GitHub.
  final String? repo;

  /// Its checkout on the office's machine.
  final String dir;

  /// Which of floorPalettes it's painted in.
  final int palette;

  /// Being cloned: on the elevator panel, but nobody can go there yet.
  final bool? cloning;
  final String addedBy;
  final int addedAt;

  /// For the elevator panel: who's there and what they're up to.
  final int workers;
  final int busy;

  /// Workers waiting on someone: a question, a permission, or a finished turn nobody looked at.
  final int waiting;
  final int people;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'repo': ?repo,
        'dir': dir,
        'palette': palette,
        'cloning': ?cloning,
        'addedBy': addedBy,
        'addedAt': addedAt,
        'workers': workers,
        'busy': busy,
        'waiting': waiting,
        'people': people,
      };
}

/// A repository the office's `gh` login can clone, for the elevator's "add a project".
class RepoChoice implements JsonObject {
  const RepoChoice({required this.name, this.description, required this.private, this.pushedAt});

  factory RepoChoice.fromJson(Map<String, dynamic> j) =>
      RepoChoice(name: asString(j['name']), description: asStringOrNull(j['description']), private: asBool(j['private']), pushedAt: asStringOrNull(j['pushedAt']));

  /// owner/name
  final String name;
  final String? description;
  final bool private;

  /// ISO time of the last push.
  final String? pushedAt;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'description': ?description, 'private': private, 'pushedAt': ?pushedAt};
}

/// Everything that belongs to the floor you're on: sent when you walk in, and when you change floors.
class FloorView implements JsonObject {
  const FloorView({
    required this.floor,
    required this.project,
    required this.workers,
    required this.issues,
    required this.pulls,
    required this.queue,
    required this.decor,
    required this.services,
    required this.dog,
    required this.jukebox,
    required this.whiteboard,
  });

  factory FloorView.fromJson(Map<String, dynamic> j) => FloorView(
        floor: asStringOrNull(j['floor']),
        project: _obj(j['project'], ProjectInfo.fromJson),
        workers: asList(j['workers'], WorkerInfo.fromJson),
        issues: GhState.fromJson(asMap(j['issues']), GhIssue.fromJson),
        pulls: GhState.fromJson(asMap(j['pulls']), GhPull.fromJson),
        queue: QueueState.fromJson(asMap(j['queue'])),
        decor: asList(j['decor'], Decoration.fromJson),
        services: ServicesState.fromJson(asMap(j['services'])),
        dog: _obj(j['dog'], DogState.fromJson),
        jukebox: JukeboxState.fromJson(asMap(j['jukebox'])),
        whiteboard: WhiteboardView.fromJson(asMap(j['whiteboard'])),
      );

  /// The floor you're on; null while the building has none.
  final String? floor;
  final ProjectInfo? project;
  final List<WorkerInfo> workers;
  final GhState<GhIssue> issues;
  final GhState<GhPull> pulls;
  final QueueState queue;

  /// Pictures on this floor's walls.
  final List<Decoration> decor;
  final ServicesState services;

  /// The floor's dog; null in a building with no floors yet.
  final DogState? dog;

  /// What the lounge jukebox is playing.
  final JukeboxState jukebox;

  /// What's drawn on this floor's whiteboard, and who's drawing.
  final WhiteboardView whiteboard;

  /// `floor`, `project` and `dog` are always sent, as null when there's none.
  @override
  Map<String, dynamic> toJson() => {
        'floor': floor,
        'project': project?.toJson(),
        'workers': _list(workers),
        'issues': issues.toJson(),
        'pulls': pulls.toJson(),
        'queue': queue.toJson(),
        'decor': [for (final d in decor) d.toJson()],
        'services': services.toJson(),
        'dog': dog?.toJson(),
        'jukebox': jukebox.toJson(),
        'whiteboard': whiteboard.toJson(),
      };
}

// ---- Accounts and the team ----------------------------------------------------------------------

/// Your own account, as [Me] names it.
class MeAccount implements JsonObject {
  const MeAccount({required this.name, required this.role});

  factory MeAccount.fromJson(Map<String, dynamic> j) => MeAccount(name: asString(j['name']), role: AccountRole.parse(j['role']));

  final String name;
  final AccountRole role;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'role': role.wire};
}

/// Who this browser is signed in as.
class Me implements JsonObject {
  const Me({this.account, required this.admin});

  factory Me.fromJson(Map<String, dynamic> j) => Me(account: _obj(j['account'], MeAccount.fromJson), admin: asBool(j['admin']));

  /// Your own account; missing when you came in with the shared office password.
  final MeAccount? account;

  /// May invite, list and revoke accounts.
  final bool admin;

  @override
  Map<String, dynamic> toJson() => {'account': ?account?.toJson(), 'admin': admin};
}

class AccountInfo implements JsonObject {
  const AccountInfo({required this.id, required this.name, required this.role, required this.createdAt, required this.createdBy, this.lastSeenAt, required this.online});

  factory AccountInfo.fromJson(Map<String, dynamic> j) => AccountInfo(
        id: asString(j['id']),
        name: asString(j['name']),
        role: AccountRole.parse(j['role']),
        createdAt: asInt(j['createdAt']),
        createdBy: asString(j['createdBy']),
        lastSeenAt: asIntOrNull(j['lastSeenAt']),
        online: asBool(j['online']),
      );

  final String id;
  final String name;
  final AccountRole role;
  final int createdAt;
  final String createdBy;
  final int? lastSeenAt;

  /// In the office right now.
  final bool online;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.wire,
        'createdAt': createdAt,
        'createdBy': createdBy,
        'lastSeenAt': ?lastSeenAt,
        'online': online,
      };
}

/// A single-use link that makes a named account: `/join#<token>`.
class AccountInvite implements JsonObject {
  const AccountInvite({required this.id, required this.token, this.name, required this.role, required this.createdBy, required this.createdAt, required this.expiresAt});

  factory AccountInvite.fromJson(Map<String, dynamic> j) => AccountInvite(
        id: asString(j['id']),
        token: asString(j['token']),
        name: asStringOrNull(j['name']),
        role: AccountRole.parse(j['role']),
        createdBy: asString(j['createdBy']),
        createdAt: asInt(j['createdAt']),
        expiresAt: asInt(j['expiresAt']),
      );

  final String id;
  final String token;

  /// The name the account gets; when missing, whoever opens the link picks one.
  final String? name;
  final AccountRole role;
  final String createdBy;
  final int createdAt;
  final int expiresAt;

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'token': token,
        'name': ?name,
        'role': role.wire,
        'createdBy': createdBy,
        'createdAt': createdAt,
        'expiresAt': expiresAt,
      };
}

/// Per-person accounts, for admins (see server/accounts.ts).
class AccountsState implements JsonObject {
  const AccountsState({required this.accounts, required this.invites, required this.sharedPassword});

  factory AccountsState.fromJson(Map<String, dynamic> j) => AccountsState(
        accounts: asList(j['accounts'], AccountInfo.fromJson),
        invites: asList(j['invites'], AccountInvite.fromJson),
        sharedPassword: asBool(j['sharedPassword']),
      );

  final List<AccountInfo> accounts;
  final List<AccountInvite> invites;

  /// Whether the shared office password still lets people in.
  final bool sharedPassword;

  @override
  Map<String, dynamic> toJson() => {'accounts': _list(accounts), 'invites': _list(invites), 'sharedPassword': sharedPassword};
}

class TeamMember implements JsonObject {
  const TeamMember({required this.name, required this.keys});

  factory TeamMember.fromJson(Map<String, dynamic> j) => TeamMember(name: asString(j['name']), keys: asInt(j['keys']));

  /// GitHub username (or the name deploy/aws.sh invited a key file under).
  final String name;
  final int keys;

  @override
  Map<String, dynamic> toJson() => {'name': name, 'keys': keys};
}

/// Who may SSH-tunnel into the office. Only offices deployed with deploy/aws.sh manage this.
class TeamState implements JsonObject {
  const TeamState({this.unavailable, this.error, this.ssh, required this.port, this.fingerprint, required this.members});

  factory TeamState.fromJson(Map<String, dynamic> j) => TeamState(
        unavailable: asStringOrNull(j['unavailable']),
        error: asStringOrNull(j['error']),
        ssh: asStringOrNull(j['ssh']),
        port: asInt(j['port']),
        fingerprint: asStringOrNull(j['fingerprint']),
        members: asList(j['members'], TeamMember.fromJson),
      );

  /// Why invites can't be managed from the office, when they can't.
  final String? unavailable;
  final String? error;

  /// user@host teammates tunnel to, e.g. office@203.0.113.7
  final String? ssh;

  /// The office's port on the box (tunnel destination).
  final int port;

  /// SHA256 fingerprint of the box's ED25519 host key, to check on first connect.
  final String? fingerprint;
  final List<TeamMember> members;

  @override
  Map<String, dynamic> toJson() => {
        'unavailable': ?unavailable,
        'error': ?error,
        'ssh': ?ssh,
        'port': port,
        'fingerprint': ?fingerprint,
        'members': _list(members),
      };
}

// ---- Services -----------------------------------------------------------------------------------

/// A web server a worker started (a dev server, a preview), found by the ports it listens on.
class ServiceInfo implements JsonObject {
  const ServiceInfo({required this.port, required this.host, required this.pid, required this.command, required this.workerId, this.cwd, this.title, required this.since});

  factory ServiceInfo.fromJson(Map<String, dynamic> j) => ServiceInfo(
        port: asInt(j['port']),
        host: asString(j['host']),
        pid: asInt(j['pid']),
        command: asString(j['command']),
        workerId: asString(j['workerId']),
        cwd: asStringOrNull(j['cwd']),
        title: asStringOrNull(j['title']),
        since: asInt(j['since']),
      );

  final int port;

  /// The address the office reaches it on, on its own machine.
  final String host;
  final int pid;

  /// Its command line, shortened, e.g. "vite --port 5173".
  final String command;

  /// The worker whose terminal started it.
  final String workerId;

  /// Its working directory relative to its floor's checkout ('' is the project root).
  final String? cwd;

  /// The `<title>` of its front page.
  final String? title;
  final int since;

  @override
  Map<String, dynamic> toJson() => {
        'port': port,
        'host': host,
        'pid': pid,
        'command': command,
        'workerId': workerId,
        'cwd': ?cwd,
        'title': ?title,
        'since': since,
      };
}

class ServicesState implements JsonObject {
  const ServicesState({required this.items, required this.port, this.ssh});

  factory ServicesState.fromJson(Map<String, dynamic> j) => ServicesState(items: asList(j['items'], ServiceInfo.fromJson), port: asInt(j['port']), ssh: asStringOrNull(j['ssh']));

  final List<ServiceInfo> items;

  /// The office's port on its machine. Service tunnels end there and the office relays them.
  final int port;

  /// user@host teammates tunnel to (offices deployed with deploy/aws.sh), e.g. office@203.0.113.7
  final String? ssh;

  @override
  Map<String, dynamic> toJson() => {'items': _list(items), 'port': port, 'ssh': ?ssh};
}

// ---- Changes ------------------------------------------------------------------------------------

/// One file a worker changed, against the base of its branch.
class ChangedFile implements JsonObject {
  const ChangedFile({
    required this.path,
    this.from,
    required this.status,
    required this.additions,
    required this.deletions,
    required this.binary,
    required this.uncommitted,
    required this.sig,
  });

  factory ChangedFile.fromJson(Map<String, dynamic> j) => ChangedFile(
        path: asString(j['path']),
        from: asStringOrNull(j['from']),
        status: ChangeStatus.parse(j['status']),
        additions: asInt(j['additions']),
        deletions: asInt(j['deletions']),
        binary: asBool(j['binary']),
        uncommitted: asBool(j['uncommitted']),
        sig: asString(j['sig']),
      );

  final String path;

  /// The old path, when the file was renamed.
  final String? from;

  /// M modified, A added, D deleted, R renamed, T type changed, ? untracked (new, never committed).
  final ChangeStatus status;
  final int additions;
  final int deletions;
  final bool binary;

  /// Not committed yet: staged, unstaged or untracked.
  final bool uncommitted;

  /// Fingerprint of the working copy (size and mtime); a new value means the diff changed.
  final String sig;

  @override
  Map<String, dynamic> toJson() => {
        'path': path,
        'from': ?from,
        'status': status.wire,
        'additions': additions,
        'deletions': deletions,
        'binary': binary,
        'uncommitted': uncommitted,
        'sig': sig,
      };
}

/// What a worker changed in its checkout, against the branch the office was opened on.
class ChangesState implements JsonObject {
  const ChangesState({
    required this.workerId,
    required this.dir,
    this.branch,
    required this.base,
    required this.ahead,
    this.subject,
    required this.files,
    required this.more,
    this.prBase,
    this.pr,
    this.busy,
    this.error,
    required this.at,
  });

  factory ChangesState.fromJson(Map<String, dynamic> j) => ChangesState(
        workerId: asString(j['workerId']),
        dir: asString(j['dir']),
        branch: asStringOrNull(j['branch']),
        base: asString(j['base']),
        ahead: asInt(j['ahead']),
        subject: asStringOrNull(j['subject']),
        files: asList(j['files'], ChangedFile.fromJson),
        more: asInt(j['more']),
        prBase: asStringOrNull(j['prBase']),
        pr: _obj(j['pr'], PrRef.fromJson),
        busy: asStringOrNull(j['busy']),
        error: asStringOrNull(j['error']),
        at: asInt(j['at']),
      );

  final String workerId;

  /// The checkout, relative to the office dir ('' is the project folder itself, shared by everyone).
  final String dir;

  /// Current branch of that checkout ('HEAD' when detached).
  final String? branch;

  /// What the diff is against: the base branch, an upstream, or 'HEAD' (uncommitted changes only).
  final String base;

  /// Commits on the branch since the base.
  final int ahead;

  /// Subject of the newest commit, when ahead > 0.
  final String? subject;
  final List<ChangedFile> files;

  /// Files left out because there were more than the office lists.
  final int more;

  /// The branch a pull request would target, when this checkout is on a branch of its own.
  final String? prBase;

  /// An open pull request for the branch.
  final PrRef? pr;

  /// A commit, discard or pull request in progress.
  final String? busy;
  final String? error;
  final int at;

  @override
  Map<String, dynamic> toJson() => {
        'workerId': workerId,
        'dir': dir,
        'branch': ?branch,
        'base': base,
        'ahead': ahead,
        'subject': ?subject,
        'files': _list(files),
        'more': more,
        'prBase': ?prBase,
        'pr': ?pr?.toJson(),
        'busy': ?busy,
        'error': ?error,
        'at': at,
      };
}

// ---- Upgrades -----------------------------------------------------------------------------------

class VersionInfo implements JsonObject {
  const VersionInfo({required this.sha, required this.subject, required this.date});

  factory VersionInfo.fromJson(Map<String, dynamic> j) => VersionInfo(sha: asString(j['sha']), subject: asString(j['subject']), date: asString(j['date']));

  final String sha;
  final String subject;

  /// ISO commit date
  final String date;

  @override
  Map<String, dynamic> toJson() => {'sha': sha, 'subject': subject, 'date': date};
}

/// One new commit upstream, in [UpgradeState.changes].
class UpgradeChange implements JsonObject {
  const UpgradeChange({required this.sha, required this.subject});

  factory UpgradeChange.fromJson(Map<String, dynamic> j) => UpgradeChange(sha: asString(j['sha']), subject: asString(j['subject']));

  final String sha;
  final String subject;

  @override
  Map<String, dynamic> toJson() => {'sha': sha, 'subject': subject};
}

/// Self-upgrade of an office installed from git by deploy/aws.sh (see server/upgrade.ts).
class UpgradeState implements JsonObject {
  const UpgradeState({
    required this.available,
    this.current,
    this.latest,
    this.changes,
    this.behind,
    this.checking,
    this.checkedAt,
    required this.phase,
    this.by,
    this.error,
  });

  factory UpgradeState.fromJson(Map<String, dynamic> j) => UpgradeState(
        available: asBool(j['available']),
        current: _obj(j['current'], VersionInfo.fromJson),
        latest: _obj(j['latest'], VersionInfo.fromJson),
        changes: j['changes'] is List ? asList(j['changes'], UpgradeChange.fromJson) : null,
        behind: asIntOrNull(j['behind']),
        checking: asBoolOrNull(j['checking']),
        checkedAt: asIntOrNull(j['checkedAt']),
        phase: UpgradePhase.parse(j['phase']),
        by: asStringOrNull(j['by']),
        error: asStringOrNull(j['error']),
      );

  /// False when the office can't upgrade itself (not installed by deploy/aws.sh).
  final bool available;
  final VersionInfo? current;

  /// Newest commit upstream, when it differs from current.
  final VersionInfo? latest;

  /// New commits since current, newest first (at most 15).
  final List<UpgradeChange>? changes;

  /// How many new commits there are in all ("50" means 50 or more).
  final int? behind;
  final bool? checking;
  final int? checkedAt;
  final UpgradePhase phase;

  /// Who started the upgrade.
  final String? by;
  final String? error;

  @override
  Map<String, dynamic> toJson() => {
        'available': available,
        'current': ?current?.toJson(),
        'latest': ?latest?.toJson(),
        'changes': ?(changes == null ? null : _list(changes!)),
        'behind': ?behind,
        'checking': ?checking,
        'checkedAt': ?checkedAt,
        'phase': phase.wire,
        'by': ?by,
        'error': ?error,
      };
}

// ---- The sky, chat and search -------------------------------------------------------------------

/// What it's like outside the windows. The server decides it, so everyone sees the same sky.
class SkyState implements JsonObject {
  const SkyState({required this.lat, required this.lon, required this.utcOffset, required this.weather, required this.intensity, this.city, this.temp});

  factory SkyState.fromJson(Map<String, dynamic> j) => SkyState(
        lat: asDouble(j['lat']),
        lon: asDouble(j['lon']),
        utcOffset: asInt(j['utcOffset']),
        weather: Weather.parse(j['weather']),
        intensity: asDouble(j['intensity']),
        city: asStringOrNull(j['city']),
        temp: asDoubleOrNull(j['temp']),
      );

  /// Where the office is, for the sun: a configured city, or a guess from the host's time zone.
  final double lat;
  final double lon;

  /// The office's clock, in minutes east of UTC.
  final int utcOffset;
  final Weather weather;

  /// 0–1: a drizzle to a downpour, a few flakes to a blizzard, haze to pea soup.
  final double intensity;

  /// The city whose live forecast this is. Unset when the weather is made up or pinned.
  final String? city;

  /// °C, from the forecast.
  final double? temp;

  @override
  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        'utcOffset': utcOffset,
        'weather': weather.wire,
        'intensity': intensity,
        'city': ?city,
        'temp': ?temp,
      };
}

class ChatLine implements JsonObject {
  const ChatLine({required this.from, required this.name, required this.color, required this.text, required this.at, this.account});

  factory ChatLine.fromJson(Map<String, dynamic> j) => ChatLine(
        from: asString(j['from']),
        name: asString(j['name']),
        color: asString(j['color'], '#888888'),
        text: asString(j['text']),
        at: asInt(j['at']),
        account: asBoolOrNull(j['account']),
      );

  final String from;
  final String name;
  final String color;
  final String text;
  final int at;

  /// Said by someone signed in with their own account.
  final bool? account;

  @override
  Map<String, dynamic> toJson() => {'from': from, 'name': name, 'color': color, 'text': text, 'at': at, 'account': ?account};
}

/// A line of a worker's terminal that matched a search.
class TerminalHit implements JsonObject {
  const TerminalHit({required this.workerId, required this.text, required this.row, required this.rows});

  factory TerminalHit.fromJson(Map<String, dynamic> j) => TerminalHit(workerId: asString(j['workerId']), text: asString(j['text']), row: asInt(j['row']), rows: asInt(j['rows']));

  final String workerId;

  /// The line, cut down around the match.
  final String text;

  /// Where it is: its row in the worker's terminal, and how many rows that terminal had.
  final int row;
  final int rows;

  @override
  Map<String, dynamic> toJson() => {'workerId': workerId, 'text': text, 'row': row, 'rows': rows};
}

/// What GET /api/search answers: matching chat and terminal lines, newest first.
class SearchResults implements JsonObject {
  const SearchResults({required this.q, required this.chat, required this.terminals, required this.more});

  factory SearchResults.fromJson(Map<String, dynamic> j) =>
      SearchResults(q: asString(j['q']), chat: asList(j['chat'], ChatLine.fromJson), terminals: asList(j['terminals'], TerminalHit.fromJson), more: asBool(j['more']));

  final String q;
  final List<ChatLine> chat;
  final List<TerminalHit> terminals;

  /// More lines matched than these.
  final bool more;

  @override
  Map<String, dynamic> toJson() => {'q': q, 'chat': _list(chat), 'terminals': _list(terminals), 'more': more};
}

/// A WebRTC ICE server, as the welcome message lists them. `urls` is one URL or several on the wire.
class IceServer implements JsonObject {
  const IceServer({required this.urls, this.username, this.credential, this.urlsIsList = true});

  factory IceServer.fromJson(Map<String, dynamic> j) {
    final u = j['urls'];
    return IceServer(
      urls: u is String ? [u] : asStringList(u),
      urlsIsList: u is! String,
      username: asStringOrNull(j['username']),
      credential: asStringOrNull(j['credential']),
    );
  }

  final List<String> urls;

  /// Whether `urls` came (and goes back out) as a list rather than a single string.
  final bool urlsIsList;
  final String? username;
  final String? credential;

  @override
  Map<String, dynamic> toJson() => {
        'urls': urlsIsList || urls.length != 1 ? urls : urls.first,
        'username': ?username,
        'credential': ?credential,
      };
}

// ---- Client → server ----------------------------------------------------------------------------

/// A message the browser sends. [toJson] gives exactly the wire shape; optional fields left null are omitted.
sealed class ClientMsg {
  const ClientMsg();

  /// The message's `t`.
  String get t;

  /// The fields beside `t`.
  Map<String, dynamic> get fields => const {};

  Map<String, dynamic> toJson() => {'t': t, ...fields};
}

class MoveCmd extends ClientMsg {
  const MoveCmd({required this.x, required this.y, required this.z, required this.rotY, required this.moving});
  final double x, y, z, rotY;
  final bool moving;
  @override
  String get t => 'move';
  @override
  Map<String, dynamic> get fields => {'x': x, 'y': y, 'z': z, 'rotY': rotY, 'moving': moving};
}

/// You reached out to use something; everyone else sees your character's arm do it. With `smoke`,
/// you lit a cigarette (or put it out) on the balcony instead.
class ActCmd extends ClientMsg {
  const ActCmd({this.smoke});
  final bool? smoke;
  @override
  String get t => 'act';
  @override
  Map<String, dynamic> get fields => {'smoke': ?smoke};
}

/// You sat down in a place on a couch, a beanbag, a chair or the bench (see seatAt in layout), or got up again (no seat).
class SitCmd extends ClientMsg {
  const SitCmd({this.seat});
  final String? seat;
  @override
  String get t => 'sit';
  @override
  Map<String, dynamic> get fields => {'seat': ?seat};
}

class ProfileCmd extends ClientMsg {
  const ProfileCmd({required this.name, required this.color, required this.look});
  final String name;
  final String color;
  final Look look;
  @override
  String get t => 'profile';
  @override
  Map<String, dynamic> get fields => {'name': name, 'color': color, 'look': look.toJson()};
}

class WorkerSpawnCmd extends ClientMsg {
  const WorkerSpawnCmd({required this.deskId, this.prompt, this.worktree, this.kind, this.provider, this.model});
  final String deskId;
  final String? prompt;
  final bool? worktree;
  final WorkerKind? kind;
  final AgentProvider? provider;
  final String? model;
  @override
  String get t => 'worker.spawn';
  @override
  Map<String, dynamic> get fields => {
        'deskId': deskId,
        'prompt': ?prompt,
        'worktree': ?worktree,
        'kind': ?kind?.wire,
        'provider': ?provider?.wire,
        'model': ?model,
      };
}

/// Base for the messages that only name a worker.
abstract class _WorkerCmd extends ClientMsg {
  const _WorkerCmd(this.workerId);
  final String workerId;
  @override
  Map<String, dynamic> get fields => {'workerId': workerId};
}

class WorkerResumeCmd extends _WorkerCmd {
  const WorkerResumeCmd(super.workerId);
  @override
  String get t => 'worker.resume';
}

class WorkerKillCmd extends ClientMsg {
  const WorkerKillCmd(this.workerId, {this.cleanup});
  final String workerId;
  final WorktreeCleanup? cleanup;
  @override
  String get t => 'worker.kill';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'cleanup': ?cleanup?.wire};
}

/// Asks what the worker's worktree holds; answered with a `worker.worktree` message.
class WorkerWorktreeCmd extends _WorkerCmd {
  const WorkerWorktreeCmd(super.workerId);
  @override
  String get t => 'worker.worktree';
}

class WorkerAttachCmd extends _WorkerCmd {
  const WorkerAttachCmd(super.workerId);
  @override
  String get t => 'worker.attach';
}

class WorkerDetachCmd extends _WorkerCmd {
  const WorkerDetachCmd(super.workerId);
  @override
  String get t => 'worker.detach';
}

class WorkerPromptCmd extends ClientMsg {
  const WorkerPromptCmd(this.workerId, this.prompt);
  final String workerId;
  final String prompt;
  @override
  String get t => 'worker.prompt';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'prompt': prompt};
}

/// Push a worktree worker's branch and open a pull request for it, drafted from its task.
class WorkerPrCmd extends _WorkerCmd {
  const WorkerPrCmd(super.workerId);
  @override
  String get t => 'worker.pr';
}

class TermInputCmd extends ClientMsg {
  const TermInputCmd(this.workerId, this.data);
  final String workerId;
  final String data;
  @override
  String get t => 'term.input';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'data': data};
}

class TermResizeCmd extends ClientMsg {
  const TermResizeCmd(this.workerId, {required this.cols, required this.rows});
  final String workerId;
  final int cols;
  final int rows;
  @override
  String get t => 'term.resize';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'cols': cols, 'rows': rows};
}

class GhRefreshCmd extends ClientMsg {
  const GhRefreshCmd();
  @override
  String get t => 'gh.refresh';
}

/// Merge a pull request; the answer comes back as gh.merged.
class GhMergeCmd extends ClientMsg {
  const GhMergeCmd({required this.number, required this.method, required this.deleteBranch, this.auto});
  final int number;
  final GhMergeMethod method;
  final bool deleteBranch;
  final bool? auto;
  @override
  String get t => 'gh.merge';
  @override
  Map<String, dynamic> get fields => {'number': number, 'method': method.wire, 'deleteBranch': deleteBranch, 'auto': ?auto};
}

/// Comment on an issue or a PR's conversation, as the server's gh account; answered with gh.commented.
class GhCommentCmd extends ClientMsg {
  const GhCommentCmd({required this.kind, required this.number, required this.body});
  final GhKind kind;
  final int number;
  final String body;
  @override
  String get t => 'gh.comment';
  @override
  Map<String, dynamic> get fields => {'kind': kind.wire, 'number': number, 'body': body};
}

/// Hit the office gong (E at the gong); everyone on the floor hears it.
class GongCmd extends ClientMsg {
  const GongCmd();
  @override
  String get t => 'gong';
}

/// Close an issue, or a pull request without merging it; the answer comes back as gh.closed.
class GhCloseCmd extends ClientMsg {
  const GhCloseCmd({required this.kind, required this.number, this.comment, this.reason, this.deleteBranch});
  final GhKind kind;
  final int number;
  final String? comment;
  final GhCloseReason? reason;
  final bool? deleteBranch;
  @override
  String get t => 'gh.close';
  @override
  Map<String, dynamic> get fields => {
        'kind': kind.wire,
        'number': number,
        'comment': ?comment,
        'reason': ?reason?.wire,
        'deleteBranch': ?deleteBranch,
      };
}

class QueueAddCmd extends ClientMsg {
  const QueueAddCmd({required this.prompt, this.title, this.issue, this.provider, this.model});
  final String prompt;
  final String? title;
  final int? issue;
  final AgentProvider? provider;
  final String? model;
  @override
  String get t => 'queue.add';
  @override
  Map<String, dynamic> get fields => {'prompt': prompt, 'title': ?title, 'issue': ?issue, 'provider': ?provider?.wire, 'model': ?model};
}

class QueueRemoveCmd extends ClientMsg {
  const QueueRemoveCmd(this.taskId);
  final String taskId;
  @override
  String get t => 'queue.remove';
  @override
  Map<String, dynamic> get fields => {'taskId': taskId};
}

/// Move a queued task up (-1) or down (+1) the queue.
class QueueMoveCmd extends ClientMsg {
  const QueueMoveCmd(this.taskId, this.delta);
  final String taskId;
  final int delta;
  @override
  String get t => 'queue.move';
  @override
  Map<String, dynamic> get fields => {'taskId': taskId, 'delta': delta};
}

/// Put a finished task back on the queue.
class QueueRetryCmd extends ClientMsg {
  const QueueRetryCmd(this.taskId);
  final String taskId;
  @override
  String get t => 'queue.retry';
  @override
  Map<String, dynamic> get fields => {'taskId': taskId};
}

/// Forget the finished tasks.
class QueueClearCmd extends ClientMsg {
  const QueueClearCmd();
  @override
  String get t => 'queue.clear';
}

class QueueLimitCmd extends ClientMsg {
  const QueueLimitCmd(this.maxWorkers);
  final int maxWorkers;
  @override
  String get t => 'queue.limit';
  @override
  Map<String, dynamic> get fields => {'maxWorkers': maxWorkers};
}

/// Set the office's Slack / Discord webhook; '' removes it.
class NotifyWebhookCmd extends ClientMsg {
  const NotifyWebhookCmd(this.url);
  final String url;
  @override
  String get t => 'notify.webhook';
  @override
  Map<String, dynamic> get fields => {'url': url};
}

/// Post a test message through the webhook; the outcome comes back as a toast.
class NotifyTestCmd extends ClientMsg {
  const NotifyTestCmd();
  @override
  String get t => 'notify.test';
}

class VoiceCmd extends ClientMsg {
  const VoiceCmd({required this.voice, required this.muted, required this.sharing});
  final bool voice;
  final bool muted;
  final bool sharing;
  @override
  String get t => 'voice';
  @override
  Map<String, dynamic> get fields => {'voice': voice, 'muted': muted, 'sharing': sharing};
}

class RtcCmd extends ClientMsg {
  const RtcCmd(this.to, this.data);
  final String to;

  /// Any JSON: an SDP description or an ICE candidate.
  final Object? data;
  @override
  String get t => 'rtc';
  @override
  Map<String, dynamic> get fields => {'to': to, 'data': data};
}

class ChatCmd extends ClientMsg {
  const ChatCmd(this.text);
  final String text;
  @override
  String get t => 'chat';
  @override
  Map<String, dynamic> get fields => {'text': text};
}

class TeamGetCmd extends ClientMsg {
  const TeamGetCmd();
  @override
  String get t => 'team.get';
}

class TeamInviteCmd extends ClientMsg {
  const TeamInviteCmd(this.github);
  final String github;
  @override
  String get t => 'team.invite';
  @override
  Map<String, dynamic> get fields => {'github': github};
}

class TeamRemoveCmd extends ClientMsg {
  const TeamRemoveCmd(this.name);
  final String name;
  @override
  String get t => 'team.remove';
  @override
  Map<String, dynamic> get fields => {'name': name};
}

/// The rest of the accounts messages are for admins only.
class AccountsGetCmd extends ClientMsg {
  const AccountsGetCmd();
  @override
  String get t => 'accounts.get';
}

class AccountsInviteCmd extends ClientMsg {
  const AccountsInviteCmd({this.name, required this.role});
  final String? name;
  final AccountRole role;
  @override
  String get t => 'accounts.invite';
  @override
  Map<String, dynamic> get fields => {'name': ?name, 'role': role.wire};
}

class AccountsCancelCmd extends ClientMsg {
  const AccountsCancelCmd(this.inviteId);
  final String inviteId;
  @override
  String get t => 'accounts.cancel';
  @override
  Map<String, dynamic> get fields => {'inviteId': inviteId};
}

class AccountsRevokeCmd extends ClientMsg {
  const AccountsRevokeCmd(this.accountId);
  final String accountId;
  @override
  String get t => 'accounts.revoke';
  @override
  Map<String, dynamic> get fields => {'accountId': accountId};
}

class AccountsRoleCmd extends ClientMsg {
  const AccountsRoleCmd(this.accountId, this.role);
  final String accountId;
  final AccountRole role;
  @override
  String get t => 'accounts.role';
  @override
  Map<String, dynamic> get fields => {'accountId': accountId, 'role': role.wire};
}

/// Let the shared office password sign people in, or stop it.
class AccountsSharedCmd extends ClientMsg {
  const AccountsSharedCmd(this.on);
  final bool on;
  @override
  String get t => 'accounts.shared';
  @override
  Map<String, dynamic> get fields => {'on': on};
}

/// Follow what a worker changed (the office polls its checkout while anyone watches).
class ChangesWatchCmd extends _WorkerCmd {
  const ChangesWatchCmd(super.workerId);
  @override
  String get t => 'changes.watch';
}

class ChangesUnwatchCmd extends _WorkerCmd {
  const ChangesUnwatchCmd(super.workerId);
  @override
  String get t => 'changes.unwatch';
}

class ChangesDiffCmd extends ClientMsg {
  const ChangesDiffCmd(this.workerId, this.path);
  final String workerId;
  final String path;
  @override
  String get t => 'changes.diff';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'path': path};
}

class ChangesCommitCmd extends ClientMsg {
  const ChangesCommitCmd(this.workerId, this.message);
  final String workerId;
  final String message;
  @override
  String get t => 'changes.commit';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'message': message};
}

/// Without a path, throws away every uncommitted change in that checkout.
class ChangesDiscardCmd extends ClientMsg {
  const ChangesDiscardCmd(this.workerId, {this.path});
  final String workerId;
  final String? path;
  @override
  String get t => 'changes.discard';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'path': ?path};
}

class ChangesPrCmd extends ClientMsg {
  const ChangesPrCmd(this.workerId, {required this.title, required this.body});
  final String workerId;
  final String title;
  final String body;
  @override
  String get t => 'changes.pr';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'title': title, 'body': body};
}

class UpgradeCheckCmd extends ClientMsg {
  const UpgradeCheckCmd();
  @override
  String get t => 'upgrade.check';
}

class UpgradeStartCmd extends ClientMsg {
  const UpgradeStartCmd();
  @override
  String get t => 'upgrade.start';
}

/// Read the Claude plan limits again now, instead of at the next poll.
class LimitsRefreshCmd extends ClientMsg {
  const LimitsRefreshCmd();
  @override
  String get t => 'limits.refresh';
}

/// Hang a picture on a wall.
class DecorAddCmd extends ClientMsg {
  const DecorAddCmd(this.decor);
  final DecorPlacement decor;
  @override
  String get t => 'decor.add';
  @override
  Map<String, dynamic> get fields => {'decor': decor.toJson()};
}

/// Move, resize, re-frame or swap the image of a picture.
class DecorUpdateCmd extends ClientMsg {
  const DecorUpdateCmd(this.id, this.decor);
  final String id;
  final DecorPatch decor;
  @override
  String get t => 'decor.update';
  @override
  Map<String, dynamic> get fields => {'id': id, 'decor': decor.toJson()};
}

class DecorRemoveCmd extends ClientMsg {
  const DecorRemoveCmd(this.id);
  final String id;
  @override
  String get t => 'decor.remove';
  @override
  Map<String, dynamic> get fields => {'id': id};
}

/// Put a tune on the jukebox (a jukeboxTunes id), or a stream; with neither, turn it back on.
class JukeboxPlayCmd extends ClientMsg {
  const JukeboxPlayCmd({this.track, this.url});
  final String? track;
  final String? url;
  @override
  String get t => 'jukebox.play';
  @override
  Map<String, dynamic> get fields => {'track': ?track, 'url': ?url};
}

/// On to the next tune.
class JukeboxSkipCmd extends ClientMsg {
  const JukeboxSkipCmd();
  @override
  String get t => 'jukebox.skip';
}

class JukeboxStopCmd extends ClientMsg {
  const JukeboxStopCmd();
  @override
  String get t => 'jukebox.stop';
}

/// You opened the whiteboard (or closed it): everyone on the floor sees who's drawing.
class WbOpenCmd extends ClientMsg {
  const WbOpenCmd();
  @override
  String get t => 'wb.open';
}

class WbCloseCmd extends ClientMsg {
  const WbCloseCmd();
  @override
  String get t => 'wb.close';
}

/// Elements you added or changed on the whiteboard; pictures go first, by POST /api/whiteboard/file.
class WbUpdateCmd extends ClientMsg {
  const WbUpdateCmd(this.elements);
  final List<WbElement> elements;
  @override
  String get t => 'wb.update';
  @override
  Map<String, dynamic> get fields => {'elements': [for (final e in elements) e.toJson()]};
}

/// Where your mouse is on the whiteboard, and what you have selected there.
class WbPointerCmd extends ClientMsg {
  const WbPointerCmd(this.pointer, {this.selected});
  final WbPointer pointer;
  final List<String>? selected;
  @override
  String get t => 'wb.pointer';
  @override
  Map<String, dynamic> get fields => {...pointer.toJson(), 'selected': ?selected};
}

/// Ride the elevator to another floor; the server answers with `floor.enter`.
class FloorGoCmd extends ClientMsg {
  const FloorGoCmd(this.floor);
  final String floor;
  @override
  String get t => 'floor.go';
  @override
  Map<String, dynamic> get fields => {'floor': floor};
}

/// The repositories that could become a floor; answered with `floor.repos`.
class FloorReposCmd extends ClientMsg {
  const FloorReposCmd({this.refresh});
  final bool? refresh;
  @override
  String get t => 'floor.repos';
  @override
  Map<String, dynamic> get fields => {'refresh': ?refresh};
}

/// Clone a repository and make it a new floor; answered with `floor.added` once it's there.
class FloorAddCmd extends ClientMsg {
  const FloorAddCmd(this.repo);
  final String repo;
  @override
  String get t => 'floor.add';
  @override
  Map<String, dynamic> get fields => {'repo': repo};
}

/// Give the dog on your floor a pat; it has to be within reach.
class DogPetCmd extends ClientMsg {
  const DogPetCmd();
  @override
  String get t => 'dog.pet';
}

/// Name the dog on your floor ('' gives it back its first name).
class DogNameCmd extends ClientMsg {
  const DogNameCmd(this.name);
  final String name;
  @override
  String get t => 'dog.name';
  @override
  Map<String, dynamic> get fields => {'name': name};
}

class PingCmd extends ClientMsg {
  const PingCmd(this.at);
  final double at;
  @override
  String get t => 'ping';
  @override
  Map<String, dynamic> get fields => {'at': at};
}

// ---- Server → client ----------------------------------------------------------------------------

/// A message the server sends. [ServerMsg.parse] reads any frame; an unknown `t` gives [UnknownMsg].
sealed class ServerMsg {
  const ServerMsg();

  /// The message's `t`.
  String get t;

  /// The fields beside `t`.
  Map<String, dynamic> get fields;

  Map<String, dynamic> toJson() => {'t': t, ...fields};

  static ServerMsg parse(Map<String, dynamic> j) {
    try {
      return _parse(j);
    } catch (_) {
      // Tolerant readers shouldn't throw, but a frame must never take the client down.
      return UnknownMsg(j);
    }
  }

  static ServerMsg _parse(Map<String, dynamic> j) {
    String s(String k) => asString(j[k]);
    return switch (j['t']) {
      'welcome' => WelcomeMsg.fromJson(j),
      'floor.enter' => FloorEnterMsg(peers: asList(j['peers'], PeerInfo.fromJson), view: FloorView.fromJson(j)),
      'floors' => FloorsMsg(asList(j['floors'], FloorInfo.fromJson)),
      'floor.repos' => FloorReposMsg(asList(j['repos'], RepoChoice.fromJson), error: asStringOrNull(j['error'])),
      'floor.added' => FloorAddedMsg(s('repo'), floor: asStringOrNull(j['floor']), error: asStringOrNull(j['error'])),
      'peer.join' => PeerJoinMsg(PeerInfo.fromJson(asMap(j['peer']))),
      'peer.update' => PeerUpdateMsg(PeerInfo.fromJson(asMap(j['peer']))),
      'peer.move' => PeerMoveMsg(
          id: s('id'),
          x: asDouble(j['x']),
          y: asDouble(j['y']),
          z: asDouble(j['z']),
          rotY: asDouble(j['rotY']),
          moving: asBool(j['moving']),
        ),
      'peer.leave' => PeerLeaveMsg(s('id')),
      'peer.act' => PeerActMsg(s('id'), smoke: asBoolOrNull(j['smoke'])),
      'worker.update' => WorkerUpdateMsg(WorkerInfo.fromJson(asMap(j['worker']))),
      'worker.remove' => WorkerRemoveMsg(s('workerId')),
      'worker.worktree' => WorkerWorktreeMsg(s('workerId'), WorktreeState.fromJson(asMap(j['state']))),
      'screen' => ScreenMsg.fromJson(j),
      'term.snapshot' => TermSnapshotMsg(workerId: s('workerId'), data: s('data'), cols: asInt(j['cols'], 80), rows: asInt(j['rows'], 24)),
      'term.data' => TermDataMsg(s('workerId'), s('data')),
      'gh.issues' => GhIssuesMsg(GhState.fromJson(asMap(j['state']), GhIssue.fromJson)),
      'gh.pulls' => GhPullsMsg(GhState.fromJson(asMap(j['state']), GhPull.fromJson)),
      'gh.merged' => GhMergedMsg(asInt(j['number']), error: asStringOrNull(j['error'])),
      'gh.commented' => GhCommentedMsg(
          kind: GhKind.parse(j['kind']),
          number: asInt(j['number']),
          comment: _obj(j['comment'], GhComment.fromJson),
          error: asStringOrNull(j['error']),
        ),
      'gong' => GongMsg(GongWhy.parse(j['why']), by: asStringOrNull(j['by']), pr: asIntOrNull(j['pr'])),
      'gh.closed' => GhClosedMsg(kind: GhKind.parse(j['kind']), number: asInt(j['number']), error: asStringOrNull(j['error'])),
      'rtc' => RtcMsg(s('from'), j['data']),
      'chat' => ChatMsg(ChatLine.fromJson(j)),
      'toast' => ToastMsg(s('text'), ToastLevel.parse(j['level'])),
      'team' => TeamMsg(TeamState.fromJson(asMap(j['state']))),
      'upgrade' => UpgradeMsg(UpgradeState.fromJson(asMap(j['state']))),
      'services' => ServicesMsg(ServicesState.fromJson(asMap(j['state']))),
      'decor' => DecorMsg(asList(j['items'], Decoration.fromJson)),
      'dog' => DogMsg(DogState.fromJson(asMap(j['dog']))),
      'jukebox' => JukeboxMsg(JukeboxState.fromJson(asMap(j['state']))),
      'wb.update' => WbUpdateMsg(asList(j['elements'], WbElement.fromJson)),
      'wb.people' => WbPeopleMsg(asStringList(j['people'])),
      'wb.pointer' => WbPointerMsg(s('id'), WbPointer.fromJson(j), selected: asStringListOrNull(j['selected'])),
      'usage' => UsageMsg(UsageState.fromJson(asMap(j['state']))),
      'limits' => LimitsMsg(PlanLimits.fromJson(asMap(j['state']))),
      'queue' => QueueMsg(QueueState.fromJson(asMap(j['state']))),
      'notify' => NotifyMsg(NotifyState.fromJson(asMap(j['state']))),
      'sky' => SkyMsg(SkyState.fromJson(asMap(j['state']))),
      'changes' => ChangesMsg(ChangesState.fromJson(asMap(j['state']))),
      'changes.diff' => ChangesDiffMsg(
          workerId: s('workerId'),
          path: s('path'),
          diff: s('diff'),
          truncated: asBool(j['truncated']),
          error: asStringOrNull(j['error']),
        ),
      'team.invited' => TeamInvitedMsg(s('github'), name: asStringOrNull(j['name']), keys: asIntOrNull(j['keys']), error: asStringOrNull(j['error'])),
      'accounts' => AccountsMsg(AccountsState.fromJson(asMap(j['state']))),
      'accounts.invited' => AccountsInvitedMsg(invite: _obj(j['invite'], AccountInvite.fromJson), error: asStringOrNull(j['error'])),
      'me' => MeMsg(Me.fromJson(asMap(j['me']))),
      'pong' => PongMsg(at: asDouble(j['at']), now: asDouble(j['now'])),
      _ => UnknownMsg(j),
    };
  }
}

/// A frame whose `t` this client doesn't know (a newer server), kept as it came.
class UnknownMsg extends ServerMsg {
  const UnknownMsg(this.raw);
  final Map<String, dynamic> raw;
  @override
  String get t => asString(raw['t']);
  @override
  Map<String, dynamic> get fields => {...raw}..remove('t');
  @override
  Map<String, dynamic> toJson() => raw;
}

/// The first message on a connection: who you are, the building, and the floor you're on.
class WelcomeMsg extends ServerMsg {
  const WelcomeMsg({
    required this.you,
    required this.peers,
    required this.floors,
    required this.projectsDir,
    required this.ice,
    required this.chat,
    required this.invites,
    required this.version,
    required this.upgrade,
    required this.usage,
    required this.limits,
    required this.me,
    required this.notify,
    required this.sky,
    required this.view,
  });

  factory WelcomeMsg.fromJson(Map<String, dynamic> j) => WelcomeMsg(
        you: asString(j['you']),
        peers: asList(j['peers'], PeerInfo.fromJson),
        floors: asList(j['floors'], FloorInfo.fromJson),
        projectsDir: asString(j['projectsDir']),
        ice: asList(j['ice'], IceServer.fromJson),
        chat: asList(j['chat'], ChatLine.fromJson),
        invites: asBool(j['invites']),
        version: asString(j['version']),
        upgrade: UpgradeState.fromJson(asMap(j['upgrade'])),
        usage: UsageState.fromJson(asMap(j['usage'])),
        limits: PlanLimits.fromJson(asMap(j['limits'])),
        me: Me.fromJson(asMap(j['me'])),
        notify: NotifyState.fromJson(asMap(j['notify'])),
        sky: SkyState.fromJson(asMap(j['sky'])),
        view: FloorView.fromJson(j),
      );

  final String you;
  final List<PeerInfo> peers;

  /// Every floor of the building, for the elevator.
  final List<FloorInfo> floors;

  /// Where new projects are cloned to, on the office's machine.
  final String projectsDir;
  final List<IceServer> ice;
  final List<ChatLine> chat;

  /// Whether teammates can be invited from the office (see TeamState).
  final bool invites;

  /// The running server's version; a change after a reconnect means the office was upgraded.
  final String version;
  final UpgradeState upgrade;
  final UsageState usage;
  final PlanLimits limits;
  final Me me;
  final NotifyState notify;

  /// Outside the windows: the same on every floor.
  final SkyState sky;

  /// The floor you're on (the welcome carries a [FloorView]'s fields flat).
  final FloorView view;

  @override
  String get t => 'welcome';
  @override
  Map<String, dynamic> get fields => {
        'you': you,
        'peers': _list(peers),
        'floors': _list(floors),
        'projectsDir': projectsDir,
        'ice': _list(ice),
        'chat': _list(chat),
        'invites': invites,
        'version': version,
        'upgrade': upgrade.toJson(),
        'usage': usage.toJson(),
        'limits': limits.toJson(),
        'me': me.toJson(),
        'notify': notify.toJson(),
        'sky': sky.toJson(),
        ...view.toJson(),
      };
}

/// You arrived on another floor: everything on it, replacing the last one's, and where everyone is now.
class FloorEnterMsg extends ServerMsg {
  const FloorEnterMsg({required this.peers, required this.view});
  final List<PeerInfo> peers;
  final FloorView view;
  @override
  String get t => 'floor.enter';
  @override
  Map<String, dynamic> get fields => {'peers': _list(peers), ...view.toJson()};
}

class FloorsMsg extends ServerMsg {
  const FloorsMsg(this.floors);
  final List<FloorInfo> floors;
  @override
  String get t => 'floors';
  @override
  Map<String, dynamic> get fields => {'floors': _list(floors)};
}

/// Sent to whoever asked.
class FloorReposMsg extends ServerMsg {
  const FloorReposMsg(this.repos, {this.error});
  final List<RepoChoice> repos;
  final String? error;
  @override
  String get t => 'floor.repos';
  @override
  Map<String, dynamic> get fields => {'repos': _list(repos), 'error': ?error};
}

/// Sent to whoever asked for the floor, once it's cloned (or couldn't be).
class FloorAddedMsg extends ServerMsg {
  const FloorAddedMsg(this.repo, {this.floor, this.error});
  final String repo;
  final String? floor;
  final String? error;
  @override
  String get t => 'floor.added';
  @override
  Map<String, dynamic> get fields => {'repo': repo, 'floor': ?floor, 'error': ?error};
}

class PeerJoinMsg extends ServerMsg {
  const PeerJoinMsg(this.peer);
  final PeerInfo peer;
  @override
  String get t => 'peer.join';
  @override
  Map<String, dynamic> get fields => {'peer': peer.toJson()};
}

class PeerUpdateMsg extends ServerMsg {
  const PeerUpdateMsg(this.peer);
  final PeerInfo peer;
  @override
  String get t => 'peer.update';
  @override
  Map<String, dynamic> get fields => {'peer': peer.toJson()};
}

class PeerMoveMsg extends ServerMsg {
  const PeerMoveMsg({required this.id, required this.x, required this.y, required this.z, required this.rotY, required this.moving});
  final String id;
  final double x, y, z, rotY;
  final bool moving;
  @override
  String get t => 'peer.move';
  @override
  Map<String, dynamic> get fields => {'id': id, 'x': x, 'y': y, 'z': z, 'rotY': rotY, 'moving': moving};
}

class PeerLeaveMsg extends ServerMsg {
  const PeerLeaveMsg(this.id);
  final String id;
  @override
  String get t => 'peer.leave';
  @override
  Map<String, dynamic> get fields => {'id': id};
}

class PeerActMsg extends ServerMsg {
  const PeerActMsg(this.id, {this.smoke});
  final String id;
  final bool? smoke;
  @override
  String get t => 'peer.act';
  @override
  Map<String, dynamic> get fields => {'id': id, 'smoke': ?smoke};
}

class WorkerUpdateMsg extends ServerMsg {
  const WorkerUpdateMsg(this.worker);
  final WorkerInfo worker;
  @override
  String get t => 'worker.update';
  @override
  Map<String, dynamic> get fields => {'worker': worker.toJson()};
}

class WorkerRemoveMsg extends ServerMsg {
  const WorkerRemoveMsg(this.workerId);
  final String workerId;
  @override
  String get t => 'worker.remove';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId};
}

class WorkerWorktreeMsg extends ServerMsg {
  const WorkerWorktreeMsg(this.workerId, this.state);
  final String workerId;
  final WorktreeState state;
  @override
  String get t => 'worker.worktree';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'state': state.toJson()};
}

/// Rows of a worker's terminal, as styled runs: every row when `full`, else just the rows that changed.
class ScreenMsg extends ServerMsg {
  const ScreenMsg({required this.workerId, required this.cols, required this.rows, required this.lines, required this.full, required this.cursor});

  factory ScreenMsg.fromJson(Map<String, dynamic> j) {
    final lines = <int, List<Run>>{};
    final raw = j['lines'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final row = int.tryParse('$k');
        if (row != null && v is List) lines[row] = [for (final r in v) Run.fromJson(r)];
      });
    }
    final c = j['cursor'];
    final cursor = c is List && c.length >= 2 ? (asInt(c[0]), asInt(c[1])) : (0, 0);
    return ScreenMsg(workerId: asString(j['workerId']), cols: asInt(j['cols'], 80), rows: asInt(j['rows'], 24), lines: lines, full: asBool(j['full']), cursor: cursor);
  }

  final String workerId;
  final int cols;
  final int rows;

  /// Row number → its runs (JSON object keys are the row numbers as strings).
  final Map<int, List<Run>> lines;
  final bool full;

  /// (x, y).
  final (int, int) cursor;

  @override
  String get t => 'screen';
  @override
  Map<String, dynamic> get fields => {
        'workerId': workerId,
        'cols': cols,
        'rows': rows,
        'lines': {for (final e in lines.entries) '${e.key}': [for (final r in e.value) r.toJson()]},
        'full': full,
        'cursor': [cursor.$1, cursor.$2],
      };
}

class TermSnapshotMsg extends ServerMsg {
  const TermSnapshotMsg({required this.workerId, required this.data, required this.cols, required this.rows});
  final String workerId;
  final String data;
  final int cols;
  final int rows;
  @override
  String get t => 'term.snapshot';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'data': data, 'cols': cols, 'rows': rows};
}

class TermDataMsg extends ServerMsg {
  const TermDataMsg(this.workerId, this.data);
  final String workerId;
  final String data;
  @override
  String get t => 'term.data';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'data': data};
}

class GhIssuesMsg extends ServerMsg {
  const GhIssuesMsg(this.state);
  final GhState<GhIssue> state;
  @override
  String get t => 'gh.issues';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class GhPullsMsg extends ServerMsg {
  const GhPullsMsg(this.state);
  final GhState<GhPull> state;
  @override
  String get t => 'gh.pulls';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

/// Sent to whoever asked for the merge.
class GhMergedMsg extends ServerMsg {
  const GhMergedMsg(this.number, {this.error});
  final int number;
  final String? error;
  @override
  String get t => 'gh.merged';
  @override
  Map<String, dynamic> get fields => {'number': number, 'error': ?error};
}

/// Sent to whoever commented: the comment as GitHub saved it, or why it wasn't.
class GhCommentedMsg extends ServerMsg {
  const GhCommentedMsg({required this.kind, required this.number, this.comment, this.error});
  final GhKind kind;
  final int number;
  final GhComment? comment;
  final String? error;
  @override
  String get t => 'gh.commented';
  @override
  Map<String, dynamic> get fields => {'kind': kind.wire, 'number': number, 'comment': ?comment?.toJson(), 'error': ?error};
}

/// The gong rings, for everyone on the floor: someone hit it, pull request `pr` merged (confetti
/// over the desk it came from), or the last task on the queue just finished (a bigger party).
class GongMsg extends ServerMsg {
  const GongMsg(this.why, {this.by, this.pr});
  final GongWhy why;
  final String? by;
  final int? pr;
  @override
  String get t => 'gong';
  @override
  Map<String, dynamic> get fields => {'why': why.wire, 'by': ?by, 'pr': ?pr};
}

/// Sent to whoever asked to close it.
class GhClosedMsg extends ServerMsg {
  const GhClosedMsg({required this.kind, required this.number, this.error});
  final GhKind kind;
  final int number;
  final String? error;
  @override
  String get t => 'gh.closed';
  @override
  Map<String, dynamic> get fields => {'kind': kind.wire, 'number': number, 'error': ?error};
}

class RtcMsg extends ServerMsg {
  const RtcMsg(this.from, this.data);
  final String from;

  /// Any JSON: an SDP description or an ICE candidate.
  final Object? data;
  @override
  String get t => 'rtc';
  @override
  Map<String, dynamic> get fields => {'from': from, 'data': data};
}

/// A chat line (its fields ride flat beside `t`).
class ChatMsg extends ServerMsg {
  const ChatMsg(this.line);
  final ChatLine line;
  @override
  String get t => 'chat';
  @override
  Map<String, dynamic> get fields => line.toJson();
}

class ToastMsg extends ServerMsg {
  const ToastMsg(this.text, this.level);
  final String text;
  final ToastLevel level;
  @override
  String get t => 'toast';
  @override
  Map<String, dynamic> get fields => {'text': text, 'level': level.wire};
}

class TeamMsg extends ServerMsg {
  const TeamMsg(this.state);
  final TeamState state;
  @override
  String get t => 'team';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class UpgradeMsg extends ServerMsg {
  const UpgradeMsg(this.state);
  final UpgradeState state;
  @override
  String get t => 'upgrade';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class ServicesMsg extends ServerMsg {
  const ServicesMsg(this.state);
  final ServicesState state;
  @override
  String get t => 'services';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class DecorMsg extends ServerMsg {
  const DecorMsg(this.items);
  final List<Decoration> items;
  @override
  String get t => 'decor';
  @override
  Map<String, dynamic> get fields => {'items': [for (final d in items) d.toJson()]};
}

/// What the dog on your floor is up to now: sent at the start of each leg of its day.
class DogMsg extends ServerMsg {
  const DogMsg(this.dog);
  final DogState dog;
  @override
  String get t => 'dog';
  @override
  Map<String, dynamic> get fields => {'dog': dog.toJson()};
}

class JukeboxMsg extends ServerMsg {
  const JukeboxMsg(this.state);
  final JukeboxState state;
  @override
  String get t => 'jukebox';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

/// Someone changed these elements on the floor's whiteboard (sent to everyone else on the floor).
class WbUpdateMsg extends ServerMsg {
  const WbUpdateMsg(this.elements);
  final List<WbElement> elements;
  @override
  String get t => 'wb.update';
  @override
  Map<String, dynamic> get fields => {'elements': [for (final e in elements) e.toJson()]};
}

/// Who has the floor's whiteboard open now.
class WbPeopleMsg extends ServerMsg {
  const WbPeopleMsg(this.people);
  final List<String> people;
  @override
  String get t => 'wb.people';
  @override
  Map<String, dynamic> get fields => {'people': people};
}

/// Someone's mouse on the whiteboard; only people who have it open get these.
class WbPointerMsg extends ServerMsg {
  const WbPointerMsg(this.id, this.pointer, {this.selected});
  final String id;
  final WbPointer pointer;
  final List<String>? selected;
  @override
  String get t => 'wb.pointer';
  @override
  Map<String, dynamic> get fields => {'id': id, ...pointer.toJson(), 'selected': ?selected};
}

class UsageMsg extends ServerMsg {
  const UsageMsg(this.state);
  final UsageState state;
  @override
  String get t => 'usage';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class LimitsMsg extends ServerMsg {
  const LimitsMsg(this.state);
  final PlanLimits state;
  @override
  String get t => 'limits';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class QueueMsg extends ServerMsg {
  const QueueMsg(this.state);
  final QueueState state;
  @override
  String get t => 'queue';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class NotifyMsg extends ServerMsg {
  const NotifyMsg(this.state);
  final NotifyState state;
  @override
  String get t => 'notify';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class SkyMsg extends ServerMsg {
  const SkyMsg(this.state);
  final SkyState state;
  @override
  String get t => 'sky';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

/// Sent to whoever watches that worker's changes, whenever they change.
class ChangesMsg extends ServerMsg {
  const ChangesMsg(this.state);
  final ChangesState state;
  @override
  String get t => 'changes';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

class ChangesDiffMsg extends ServerMsg {
  const ChangesDiffMsg({required this.workerId, required this.path, required this.diff, required this.truncated, this.error});
  final String workerId;
  final String path;
  final String diff;
  final bool truncated;
  final String? error;
  @override
  String get t => 'changes.diff';
  @override
  Map<String, dynamic> get fields => {'workerId': workerId, 'path': path, 'diff': diff, 'truncated': truncated, 'error': ?error};
}

/// Sent to whoever asked for the invite.
class TeamInvitedMsg extends ServerMsg {
  const TeamInvitedMsg(this.github, {this.name, this.keys, this.error});
  final String github;
  final String? name;
  final int? keys;
  final String? error;
  @override
  String get t => 'team.invited';
  @override
  Map<String, dynamic> get fields => {'github': github, 'name': ?name, 'keys': ?keys, 'error': ?error};
}

/// Sent to admins, when asked and whenever accounts change.
class AccountsMsg extends ServerMsg {
  const AccountsMsg(this.state);
  final AccountsState state;
  @override
  String get t => 'accounts';
  @override
  Map<String, dynamic> get fields => {'state': state.toJson()};
}

/// Sent to whoever made the invite.
class AccountsInvitedMsg extends ServerMsg {
  const AccountsInvitedMsg({this.invite, this.error});
  final AccountInvite? invite;
  final String? error;
  @override
  String get t => 'accounts.invited';
  @override
  Map<String, dynamic> get fields => {'invite': ?invite?.toJson(), 'error': ?error};
}

/// Your role changed.
class MeMsg extends ServerMsg {
  const MeMsg(this.me);
  final Me me;
  @override
  String get t => 'me';
  @override
  Map<String, dynamic> get fields => {'me': me.toJson()};
}

/// `now` is the office's clock as it answered, which the jukebox keeps time by.
class PongMsg extends ServerMsg {
  const PongMsg({required this.at, required this.now});
  final double at;
  final double now;
  @override
  String get t => 'pong';
  @override
  Map<String, dynamic> get fields => {'at': at, 'now': now};
}

// ---- Helpers ------------------------------------------------------------------------------------

T? _obj<T>(Object? v, T Function(Map<String, dynamic>) read) => v is Map ? read(Map<String, dynamic>.from(v)) : null;

List<Map<String, dynamic>> _list(List<JsonObject> xs) => [for (final x in xs) x.toJson()];
