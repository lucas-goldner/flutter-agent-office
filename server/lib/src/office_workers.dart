// The office's workers, for the agents working in it: what `office-workers` and the agent-office MCP
// server (workers_cmd.dart) get from the /office/workers endpoint on the loopback hook port, and how
// their requests are read. The endpoint itself is in server.dart, next to the board agents' queue.
// Port of upstream's src/server/office-workers.ts.

import 'dart:async';
import 'dart:convert';

import 'package:office_shared/shared.dart' hide Floor;
import 'package:path/path.dart' as p;

import 'floor.dart';
import 'github.dart' show gh;
import 'leave_on_merge.dart';
import 'providers/provider.dart' show writePrivate;

/// What a floor knows about its workers' pull requests.
typedef PullsView = ({List<GhPull> pulls, List<QueueTask> tasks, List<GhPull>? Function(String floor)? pullsOf});

/// How long a task or activity line gets.
const _line = 160;

String? _clip(String? s) {
  final t = s?.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t == null || t.isEmpty) return null;
  return t.length > _line ? '${t.substring(0, _line - 1)}…' : t;
}

/// One worker as an agent sees it: enough to pick the ones to send home, and say why.
Map<String, Object?> workerRow(WorkerInfo w, PullsView view, [String? me]) {
  final seat = deskById[w.deskId];
  final pr = workerPr(w, view.pulls, view.tasks);
  final pull = pr == null ? null : view.pulls.where((x) => x.number == pr.number).firstOrNull;
  final landed = landedWork(w, view.pulls, view.tasks, view.pullsOf);
  final staying = landed != null ? notLeaving(w) : null;
  final task = _clip(w.task != null ? '${w.task!.name}: ${w.task!.summary}' : w.prompt);
  final activity = _clip(w.activity);
  final station = seat?.station;
  final wt = w.worktree;
  final repos = w.repos;
  return {
    'id': w.id,
    'name': w.name,
    'kind': w.kind.wire,
    'provider': ?w.provider?.wire,
    'model': ?w.model,
    'desk': seat?.label ?? w.deskId,
    'status': w.status.wire,
    if (station != null) 'board': stationAgent[station]!.name,
    if (w.meeting != null) 'meeting': true,
    if (w.id == me) 'you': true,
    'task': ?task,
    'activity': ?activity,
    'hiredBy': w.createdBy,
    'hiredAt': DateTime.fromMillisecondsSinceEpoch(w.createdAt, isUtc: true).toIso8601String(),
    if (w.viewers.isNotEmpty) 'viewers': [...w.viewers],
    if (wt != null) 'worktree': {'path': wt.path, 'branch': wt.branch, if (w.lost != null) 'deleted': true},
    if (repos != null && repos.isNotEmpty)
      'repos': [
        for (final r in repos) {'name': r.name, 'branch': r.branch, 'pr': ?r.pr?.number},
      ],
    if (pr != null)
      'pr': {
        'number': pr.number,
        'state': pr.state.name,
        if (pull != null) 'title': pull.title,
        if (pull != null) 'url': pull.url,
      },
    'merged': landed != null,
    'staying': ?staying,
  };
}

/// The worker [key] names: its id, or its name in any case (a shell's without the 🐚). `error` when
/// there's no such worker, saying who there is.
({WorkerInfo? worker, String? error}) findWorker(List<WorkerInfo> workers, String key) {
  ({WorkerInfo? worker, String? error}) fail(String e) => (worker: null, error: e);
  final k = key.trim();
  if (k.isEmpty) return fail('Say which worker: its name or id');
  final byId = workers.where((w) => w.id == k).firstOrNull;
  if (byId != null) return (worker: byId, error: null);
  String plain(String name) => name.replaceFirst(RegExp(r'\s*🐚$'), '').trim().toLowerCase();
  final named = workers.where((w) => plain(w.name) == plain(k)).toList();
  if (named.length == 1) return (worker: named.first, error: null);
  if (named.length > 1) {
    return fail('More than one worker is called $k: use an id (${named.map((w) => w.id).join(', ')})');
  }
  return fail(
    'No worker here is called $k${workers.isNotEmpty ? " (there's ${workers.map((w) => w.name).join(', ')})" : ' (nobody is at a desk)'}',
  );
}

const cleanupChoices = ['auto', 'keep', 'worktree', 'all'];

/// What sending home was asked: these workers, or every one whose work landed.
typedef HomeRequest = ({List<String> workers, bool merged, WorktreeCleanup? cleanup});

/// A request to send workers home, read from its JSON body; `error` says what's wrong with it.
({HomeRequest? ask, String? error}) readHomeRequest(Object? body) {
  ({HomeRequest? ask, String? error}) fail(String e) => (ask: null, error: e);
  final b = body is Map ? body : const {};
  final list = b['workers'] ?? (b['worker'] == null ? const [] : [b['worker']]);
  if (list is! List || list.any((x) => x is! String)) return fail('workers is a list of worker names or ids');
  final workers = {for (final x in list.cast<String>()) x.trim()}.where((x) => x.isNotEmpty).toList();
  final merged = b['merged'] == true;
  if (workers.isEmpty && !merged) {
    return fail('Say who: workers (names or ids), or merged: true for every worker whose pull request merged');
  }
  if (workers.isNotEmpty && merged) return fail('Give workers or merged: true, not both');
  if (workers.length > 64) return fail('At most 64 workers at a time');
  final c = b['cleanup'];
  if (c != null && !cleanupChoices.contains(c)) return fail('cleanup is one of ${cleanupChoices.join(', ')}');
  final cleanup = c == null || c == 'auto' ? null : WorktreeCleanup.values.firstWhere((x) => x.wire == c);
  return (ask: (workers: workers, merged: merged, cleanup: cleanup), error: null);
}

/// A request to hire a worker, read from its JSON body.
typedef HireRequest = ({
  String prompt,
  AgentProvider? provider,
  String? model,
  AgentEffort? effort,

  /// Its own git worktree; null leaves it to the office (yes, in a git checkout).
  bool? worktree,
  String? desk,
  int? issue,
});

({HireRequest? ask, String? error}) readHireRequest(Object? body, List<AgentProvider> providers) {
  ({HireRequest? ask, String? error}) fail(String e) => (ask: null, error: e);
  final b = body is Map ? body : const {};
  final prompt = b['prompt'] is String ? (b['prompt'] as String).replaceAll(RegExp(r'\r\n?'), '\n').trim() : '';
  if (prompt.isEmpty) return fail('Give the new worker its task: prompt');
  if (prompt.length > 20000) return fail('The prompt is over 20000 characters');
  final provider = AgentProvider.tryParse(b['provider']);
  if (b['provider'] != null && (provider == null || !providers.contains(provider))) {
    return fail('provider is one of ${providers.map((x) => x.wire).join(', ')}');
  }
  final model = b['model'];
  if (model != null && (model is! String || model.trim().isEmpty || model.length > 200)) {
    return fail('model is a model name');
  }
  final effort = AgentEffort.tryParse(b['effort']);
  if (b['effort'] != null && effort == null) return fail('effort is one of low, medium, high, xhigh, max');
  if (b['worktree'] != null && b['worktree'] is! bool) return fail('worktree is true or false');
  // Board kiosks and the meeting table seat their own: see station.prompt and meetings.dart.
  final desk = b['desk'];
  final seat = desk is String ? deskById[desk] : null;
  if (desk != null && (seat == null || seat.station != null || seat.room)) {
    return fail("desk is a desk or bean bag's id, like desk-3");
  }
  final issue = b['issue'];
  if (issue != null && !(issue is int && issue > 0)) return fail('issue is an issue number');
  return (
    ask: (
      prompt: prompt,
      provider: provider,
      model: model is String ? model.trim() : null,
      effort: effort,
      worktree: b['worktree'] as bool?,
      desk: desk as String?,
      issue: issue as int?,
    ),
    error: null,
  );
}

/// A request to say which pull request is a worker's: its number, or its URL (then `repo` is whose it
/// is). With neither (unlink: true), the worker's is taken off. `worker` is whose: the worker asking,
/// when it doesn't say.
typedef PrRequest = ({String? worker, int? pr, String? repo});

({PrRequest? ask, String? error}) readPrRequest(Object? body) {
  ({PrRequest? ask, String? error}) fail(String e) => (ask: null, error: e);
  final b = body is Map ? body : const {};
  final w = b['worker'];
  if (w != null && (w is! String || w.trim().isEmpty)) return fail('worker is a worker name or id');
  final who = w is String ? w.trim() : null;
  if (b['unlink'] == true) {
    return b['pr'] == null
        ? (ask: (worker: who, pr: null, repo: null), error: null)
        : fail('Give pr or unlink: true, not both');
  }
  final raw = b['pr'];
  final text = raw is String ? raw.trim() : '';
  final url = RegExp(
    r'^https?://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)(?:[/?#].*)?$',
    caseSensitive: false,
  ).firstMatch(text);
  final n = raw is int
      ? raw
      : url != null
      ? int.tryParse(url.group(2)!)
      : RegExp(r'^#?\d+$').hasMatch(text)
      ? int.tryParse(text.replaceFirst('#', ''))
      : null;
  if (n == null || n < 1) {
    return fail("Say which pull request: pr, its number or its URL (or unlink: true to take the worker's off)");
  }
  return (ask: (worker: who, pr: n, repo: url?.group(1)), error: null);
}

// --- The MCP server -------------------------------------------------------------------------------

/// The MCP server's name, which agents put before its tools (Claude Code: mcp__agent-office__send_home).
const mcpName = 'agent-office';

/// What it needs from the worker's environment; Codex hands an MCP server only what it's told to.
const _mcpEnv = ['AGENT_OFFICE_HOOK_URL', 'AGENT_OFFICE_WORKER_ID', 'AGENT_OFFICE_HOOK_TOKEN'];

/// Its tools that only look, which Claude Code workers may call without asking.
const mcpReadOnly = ['mcp__${mcpName}__list_workers'];

/// Writes Claude Code's --mcp-config file for the MCP server ([command] is the office's own
/// `workers mcp`) and returns its path. The same for every worker: each one's identity is in its
/// environment, which Claude Code hands its MCP servers.
String writeClaudeMcpConfig(String dataDir, List<String> command) {
  final file = p.join(dataDir, 'agent-office-mcp.json');
  final config = {
    'mcpServers': {
      mcpName: {'type': 'stdio', 'command': command.first, 'args': command.sublist(1)},
    },
  };
  writePrivate(file, const JsonEncoder.withIndent('  ').convert(config));
  return file;
}

/// Codex's -c overrides for the MCP server, with the office's variables passed on to it.
List<String> codexMcpArgs(List<String> command) {
  // TOML basic strings and arrays read JSON's.
  const key = 'mcp_servers.$mcpName';
  return [
    '-c',
    '$key.command=${jsonEncode(command.first)}',
    '-c',
    '$key.args=${jsonEncode(command.sublist(1))}',
    '-c',
    '$key.env_vars=${jsonEncode(_mcpEnv)}',
  ];
}

/// OpenCode's `mcp` config entry for the MCP server; OpenCode hands it its environment.
Map<String, Object?> openCodeMcp(List<String> command) => {
  mcpName: {'type': 'local', 'command': command, 'enabled': true},
};

// --- The endpoint ---------------------------------------------------------------------------------

/// What the /office/workers endpoint needs of the office (see server.dart).
abstract interface class OfficeWorkersContext {
  /// The floor a worker sits on.
  Floor? workerFloor(String workerId);

  /// A floor of the building, by id; null once it closed.
  Floor? floor(String id);

  /// ⚙️ Settings: a worker whose pull request merged goes home by itself.
  bool get leaveOnMerge;

  /// Why hiring is paused (the budget), if it is.
  String? get hiringPaused;

  void toastFloor(Floor floor, String text, [ToastLevel? level]);
}

/// An answer from the endpoint: its status and JSON body.
typedef OfficeWorkersReply = ({int status, Map<String, Object?> body});

OfficeWorkersReply _reply(int status, Map<String, Object?> body) => (status: status, body: body);

/// Pull request [n] on a floor, for a worker to have as its own: one that's open, or merged and still
/// on the floor's list. `error` says why it can't be.
Future<({PrRef? pr, String? error})> _pullOf(Floor floor, int n, String? repo) async {
  ({PrRef? pr, String? error}) fail(String e) => (pr: null, error: e);
  final here = floor.def.repo;
  if (repo != null && here != null && repo.toLowerCase() != here.toLowerCase()) {
    return fail('That pull request is in $repo, and this floor is $here');
  }
  final listed = floor.github.pulls.items.where((x) => x.number == n).firstOrNull;
  String url, state;
  if (listed != null) {
    url = listed.url;
    state = listed.state;
  } else {
    try {
      final view = jsonDecode(await gh(['pr', 'view', '$n', '--json', 'url,state'], floor.dir));
      url = view is Map ? '${view['url']}' : '';
      state = view is Map ? '${view['state']}' : '';
    } catch (err) {
      return fail('No pull request #$n here: $err');
    }
  }
  if (state == 'CLOSED') return fail('PR #$n was closed without merging');
  // The office follows the open ones and the last ones merged: an older one would look open for good.
  if (listed == null && state == 'MERGED') {
    return fail('PR #$n merged too long ago for the office to follow: send the worker home by name instead');
  }
  return (pr: PrRef(number: n, url: url), error: null);
}

/// The floor's workers, for any worker on it (see workers_cmd.dart, the command and MCP server that
/// call it): GET lists them, POST hires one, POST /home sends some home (its worktree and branch go
/// too, unless they hold work), POST /tell types a prompt to one, POST /pr says which pull request is
/// one's (for one the office couldn't tell by itself). The worker's own hook token says who's asking,
/// and the floor hears who did what, as from anyone. [action] is the path after /office/workers;
/// [body] the request's text.
Future<OfficeWorkersReply> officeWorkers(
  OfficeWorkersContext ctx, {
  required String method,
  required String action,
  required String workerId,
  required String token,
  String body = '',
}) async {
  final floor = ctx.workerFloor(workerId);
  final me = floor?.workers.authenticate(workerId, token);
  if (floor == null || me == null) {
    return _reply(401, {
      'error': 'Send your own AGENT_OFFICE_WORKER_ID as ?worker= and AGENT_OFFICE_HOOK_TOKEN as the bearer token',
    });
  }
  final who = me.name;
  final PullsView view = (
    pulls: floor.github.pulls.items,
    tasks: floor.queue.state().tasks,
    pullsOf: (id) => ctx.floor(id)?.github.pulls.items,
  );
  Map<String, Object?>? row(String id) {
    final w = floor.workers.get(id);
    return w == null ? null : workerRow(w, view, me.id);
  }

  if (method == 'GET' && action.isEmpty) {
    final free = nextFreeSeat(floor.workers.deskOccupied);
    final paused = ctx.hiringPaused;
    return _reply(200, {
      'floor': {'id': floor.id, 'name': floor.def.name, 'repo': floor.def.repo, 'branch': floor.project.branch},
      'you': me.id,
      'leaveOnMerge': ctx.leaveOnMerge,
      'providers': [for (final x in floor.project.agentProviders) x.wire],
      'defaultProvider': floor.workers.officeDefault.provider.wire,
      'freeDesk': free?.id,
      'hiringPaused': ?paused,
      'workers': [for (final w in floor.workers.list()) workerRow(w, view, me.id)],
    });
  }
  if (method != 'POST' || !const ['', '/home', '/tell', '/pr'].contains(action)) {
    return _reply(405, {
      'error':
          'GET /office/workers, or POST to /office/workers, /office/workers/home, /office/workers/tell or /office/workers/pr',
    });
  }
  Object? json;
  try {
    json = body.trim().isEmpty ? const <String, Object?>{} : jsonDecode(body);
  } catch (_) {
    return _reply(400, {'error': 'Send JSON'});
  }

  if (action == '/home') {
    final read = readHomeRequest(json);
    final ask = read.ask;
    if (ask == null) return _reply(400, {'error': read.error});
    final results = <Map<String, Object?>>[];
    final going = <({WorkerInfo w, String? why})>[];
    if (ask.merged) {
      for (final w in floor.workers.list()) {
        final l = floor.landed(w);
        if (l == null) continue;
        final prs = l.prs;
        final why = prs != null && prs.isNotEmpty
            ? 'its pull requests merged (${prs.join(', ')})'
            : 'PR #${l.pr} merged';
        final staying = w.id == me.id ? "that's you" : notLeaving(w);
        if (staying != null) {
          results.add({'worker': w.name, 'id': w.id, 'skipped': "$why, but it's $staying"});
        } else {
          going.add((w: w, why: why));
        }
      }
    } else {
      for (final key in ask.workers) {
        final found = findWorker(floor.workers.list(), key);
        final w = found.worker;
        if (w == null) {
          results.add({'worker': key, 'error': found.error});
        } else if (w.id == me.id) {
          results.add({'worker': w.name, 'id': w.id, 'error': "That's you: someone else has to send you home"});
        } else if (!going.any((g) => g.w.id == w.id)) {
          going.add((w: w, why: null));
        }
      }
    }
    // One at a time: git takes a lock on the repository's refs to delete a branch.
    for (final (:w, :why) in going) {
      if (floor.workers.get(w.id)?.createdAt != w.createdAt) {
        results.add({'worker': w.name, 'id': w.id, 'skipped': 'it had already gone'});
        continue;
      }
      ctx.toastFloor(floor, why != null ? '🏠 $who sent ${w.name} home: $why' : '$who sent ${w.name} home');
      final r = await floor.sendHome(w.id, ask.cleanup);
      if (r.note != null) ctx.toastFloor(floor, r.note!);
      if (r.error != null) ctx.toastFloor(floor, r.error!, ToastLevel.warn);
      results.add({'worker': w.name, 'id': w.id, 'went': true, 'note': ?r.note, 'error': ?r.error});
    }
    return _reply(200, {'results': results});
  }

  if (action == '/tell') {
    final b = json is Map ? json : const {};
    final key = b['worker'] is String ? b['worker'] as String : '';
    final found = findWorker(floor.workers.list(), key.length > 64 ? key.substring(0, 64) : key);
    final w = found.worker;
    if (w == null) return _reply(404, {'error': found.error});
    if (w.id == me.id) return _reply(400, {'error': "That's you"});
    // A shell would run it as a command, in someone's terminal.
    if (w.kind != WorkerKind.agent) return _reply(400, {'error': '${w.name} is a shell, not an agent'});
    final raw = b['prompt'] is String ? b['prompt'] as String : '';
    final text = (raw.length > 20000 ? raw.substring(0, 20000) : raw).replaceAll(RegExp(r'\r\n?'), '\n').trim();
    if (text.isEmpty) return _reply(400, {'error': 'Say what to tell it: prompt'});
    var err = floor.workers.prompt(w.id, text, who);
    // Stopped or asleep: it wakes up with this as its next message.
    if (err == 'Worker is not running') err = floor.workers.resume(w.id, text);
    if (err != null) return _reply(400, {'error': err});
    return _reply(200, {'ok': true, 'worker': row(w.id)});
  }

  if (action == '/pr') {
    final read = readPrRequest(json);
    final ask = read.ask;
    if (ask == null) return _reply(400, {'error': read.error});
    WorkerInfo w = me;
    if (ask.worker != null) {
      final found = findWorker(floor.workers.list(), ask.worker!);
      if (found.worker == null) return _reply(404, {'error': found.error});
      w = found.worker!;
    }
    if (w.kind != WorkerKind.agent) return _reply(400, {'error': '${w.name} is a shell, not an agent'});
    PrRef? pr;
    if (ask.pr != null) {
      final r = await _pullOf(floor, ask.pr!, ask.repo);
      if (r.error != null) return _reply(400, {'error': r.error});
      pr = r.pr;
    }
    final err = floor.workers.linkPr(w.id, pr);
    if (err != null) return _reply(404, {'error': err});
    final whose = w.id == me.id ? 'its own' : "${w.name}'s";
    ctx.toastFloor(
      floor,
      pr != null
          ? '$who said PR #${pr.number} is $whose'
          : '$who said ${w.id == me.id ? 'it has' : '${w.name} has'} no pull request',
    );
    return _reply(200, {'ok': true, 'worker': row(w.id)});
  }

  final read = readHireRequest(json, floor.project.agentProviders);
  final ask = read.ask;
  if (ask == null) return _reply(400, {'error': read.error});
  final desk = ask.desk ?? nextFreeSeat(floor.workers.deskOccupied)?.id;
  if (desk == null) return _reply(409, {'error': 'Every desk and bean bag is taken: send someone home first'});
  // A model or effort is the office's default worker's unless it says whose.
  final provider =
      ask.provider ?? (ask.model != null || ask.effort != null ? floor.workers.officeDefault.provider : null);
  final worktree = ask.worktree ?? (floor.project.branch?.isNotEmpty ?? false);
  // Its worktree starts from what's on GitHub now, like one hired from a desk.
  if (worktree) await floor.workers.fetchBase();
  if (ctx.floor(floor.id) != floor) return _reply(410, {'error': 'This floor closed'});
  final r = floor.workers.spawn(desk, who, ask.prompt, worktree, WorkerKind.agent, provider, ask.model, ask.effort);
  final hired = r.worker;
  if (hired == null) return _reply(400, {'error': r.error});
  ctx.toastFloor(floor, '$who hired ${hired.name}${ask.issue != null ? ' for issue #${ask.issue}' : ' with a task'}');
  final n = ask.issue;
  if (n != null) {
    floor.queue.dropIssue(n);
    unawaited(
      floor.github.claim(n).then((e) {
        if (e != null) ctx.toastFloor(floor, "Couldn't assign issue #$n on GitHub: $e", ToastLevel.warn);
      }),
    );
  }
  return _reply(200, {'ok': true, 'worker': row(hired.id)});
}
