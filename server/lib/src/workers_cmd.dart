// `agent-office workers` (and the `office-workers` command the office puts on every worker's PATH):
// the office's workers from inside Agent Office: who's at which desk and where their pull requests
// stand, hiring one, sending some home (their worktrees and branches with them), telling one
// something and saying which pull request is one's. Each worker has its own address and token in
// AGENT_OFFICE_HOOK_URL, AGENT_OFFICE_WORKER_ID and AGENT_OFFICE_HOOK_TOKEN; this talks to the
// /office/workers endpoint with them (see office_workers.dart). `office-workers mcp` is the same as an
// MCP server on stdio, which the office hands the agents that take one. Port of upstream's
// bin/office-workers.js.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const workersUsage = '''Usage:
  office-workers list [--json]                  everyone at a desk on this floor: status, task,
                                                branch and pull request (merged = free to go home)
  office-workers hire [options] <<'EOF'         hire a worker at a free desk; its task on stdin
  …the task…                                    (or --prompt "…"). Options: --provider <name>
  EOF                                           --model <m> --effort <e> --desk <id> --issue <n>
                                                --no-worktree
  office-workers home <name|id>... [--cleanup auto|keep|worktree|all]
                                                send workers home. auto (the default) deletes each
                                                one's worktree and branch unless they hold work
                                                that isn't on GitHub, and says what it kept
  office-workers home --merged                  send home everyone whose pull request merged
  office-workers tell <name|id> <<'EOF'         type a prompt to a worker (or --prompt "…")
  office-workers pr <number|url> [--worker <name|id>]
                                                say which pull request is a worker's (yours, without
                                                --worker), when the list doesn't show it: the office
                                                only knows one by itself when it was opened from the
                                                desk, from the worker's own branch, or by a Claude
                                                Code worker running gh pr create
  office-workers pr --none [--worker <name|id>] take that pull request off the worker again
  office-workers mcp                            serve these as MCP tools on stdio''';

/// A mistake in how the command was called: the usage is shown with it.
class WorkersUsageError implements Exception {
  WorkersUsageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Something that went wrong talking to the office, or that it said no to.
class WorkersError implements Exception {
  WorkersError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _envKeys = ['AGENT_OFFICE_HOOK_URL', 'AGENT_OFFICE_WORKER_ID', 'AGENT_OFFICE_HOOK_TOKEN'];
const cleanups = ['auto', 'keep', 'worktree', 'all'];
const efforts = ['low', 'medium', 'high', 'xhigh', 'max'];

/// How long the office may take to come back when it's restarting (a dev reload, an upgrade).
const _retry = Duration(seconds: 6);

/// Sending several workers home waits on git for each; hiring may fetch from GitHub first.
const _timeouts = {
  'list': Duration(seconds: 15),
  'tell': Duration(seconds: 15),
  'pr': Duration(seconds: 45),
  'hire': Duration(seconds: 90),
  'home': Duration(seconds: 300),
};

/// Where each call goes, under /office/workers.
const _paths = {'list': '', 'hire': '', 'home': '/home', 'tell': '/tell', 'pr': '/pr'};

/// Reads `--flag value` and `--flag=value` options, and the words that aren't options.
({Map<String, Object> opts, List<String> words}) _options(List<String> args, List<String> valued, List<String> bare) {
  final opts = <String, Object>{};
  final words = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) {
      if (arg.startsWith('-') && arg.length > 1) throw WorkersUsageError('Unknown option: $arg');
      words.add(arg);
      continue;
    }
    final eq = arg.indexOf('=');
    final flag = eq > 0 ? arg.substring(0, eq) : arg;
    if (bare.contains(flag)) {
      if (eq > 0) throw WorkersUsageError('$flag takes no value');
      opts[flag] = true;
    } else if (valued.contains(flag)) {
      if (eq > 0) {
        opts[flag] = arg.substring(eq + 1);
      } else if (i + 1 < args.length) {
        opts[flag] = args[++i];
      } else {
        throw WorkersUsageError('$flag needs a value');
      }
    } else {
      throw WorkersUsageError('Unknown option: $flag');
    }
  }
  return (opts: opts, words: words);
}

/// What the command line asks for: `cmd` is help, mcp, list, home, tell, pr or hire, with the rest
/// of what was asked (the body sent to the office, mostly).
Map<String, Object?> parseWorkersArgs(List<String> argv) {
  bool help(String a) => a == '-h' || a == '--help';
  if (argv.isEmpty || argv[0] == 'help' || help(argv[0]) || argv.skip(1).any(help)) return {'cmd': 'help'};
  final cmd = argv[0];
  final rest = argv.sublist(1);
  if (cmd == 'mcp') {
    if (rest.isNotEmpty) throw WorkersUsageError('mcp takes no arguments (got ${rest.join(' ')})');
    return {'cmd': 'mcp'};
  }
  if (cmd == 'list' || cmd == 'ls') {
    final o = _options(rest, [], ['--json']);
    if (o.words.isNotEmpty) throw WorkersUsageError('list takes no arguments (got ${o.words.join(' ')})');
    return {'cmd': 'list', 'json': o.opts['--json'] == true};
  }
  // send-home, after the MCP tool, which is what an agent reaches for.
  if (cmd == 'home' || cmd == 'send-home') {
    final o = _options(rest, ['--cleanup'], ['--merged', '--json']);
    final merged = o.opts['--merged'] == true;
    if (o.words.isEmpty && !merged) {
      throw WorkersUsageError(
        'Say who goes home: their names or ids, or --merged for everyone whose pull request merged',
      );
    }
    if (o.words.isNotEmpty && merged) throw WorkersUsageError('Give names or --merged, not both');
    final cleanup = o.opts['--cleanup'];
    if (cleanup != null && !cleanups.contains('$cleanup')) {
      throw WorkersUsageError('--cleanup is one of ${cleanups.join(', ')}');
    }
    return {'cmd': 'home', 'workers': o.words, 'merged': merged, 'cleanup': ?cleanup, 'json': o.opts['--json'] == true};
  }
  if (cmd == 'tell') {
    final o = _options(rest, ['--prompt'], []);
    if (o.words.length != 1) {
      throw WorkersUsageError('tell takes one worker, its name or id, with the prompt on stdin or --prompt "…"');
    }
    return {'cmd': 'tell', 'worker': o.words[0], 'prompt': ?o.opts['--prompt']};
  }
  // link-pr, after the MCP tool.
  if (cmd == 'pr' || cmd == 'link-pr') {
    final o = _options(rest, ['--worker'], ['--none', '--json']);
    final none = o.opts['--none'] == true;
    if (none ? o.words.isNotEmpty : o.words.length != 1) {
      throw WorkersUsageError(
        "pr takes one pull request, its number or URL, or --none to take it off (with --worker <name|id> when the worker isn't you)",
      );
    }
    return {
      'cmd': 'pr',
      if (none) 'unlink': true else 'pr': o.words[0],
      if (o.opts['--worker'] != null) 'worker': '${o.opts['--worker']}'.trim(),
      'json': o.opts['--json'] == true,
    };
  }
  if (cmd == 'hire') {
    final o = _options(
      rest,
      ['--prompt', '--provider', '--model', '--effort', '--desk', '--issue'],
      ['--no-worktree', '--json'],
    );
    if (o.words.isNotEmpty) {
      throw WorkersUsageError('Unexpected argument: ${o.words[0]} (give the task on stdin or with --prompt)');
    }
    final opts = o.opts;
    final out = <String, Object?>{'cmd': 'hire', 'json': opts['--json'] == true};
    if (opts['--prompt'] != null) out['prompt'] = opts['--prompt'];
    if (opts['--provider'] != null) out['provider'] = '${opts['--provider']}'.trim();
    if (opts['--model'] != null) out['model'] = '${opts['--model']}'.trim();
    if (opts['--desk'] != null) out['desk'] = '${opts['--desk']}'.trim();
    if (opts['--no-worktree'] == true) out['worktree'] = false;
    if (opts['--effort'] != null) {
      if (!efforts.contains('${opts['--effort']}')) throw WorkersUsageError('--effort is one of ${efforts.join(', ')}');
      out['effort'] = opts['--effort'];
    }
    if (opts['--issue'] != null) {
      final n = RegExp(r'^#?(\d+)$').firstMatch('${opts['--issue']}'.trim());
      final number = n == null ? 0 : int.parse(n.group(1)!);
      if (number < 1) {
        throw WorkersUsageError('--issue takes an issue number, e.g. --issue 12 (got ${opts['--issue']})');
      }
      out['issue'] = number;
    }
    return out;
  }
  throw WorkersUsageError('Unknown command: $cmd');
}

/// The office's address and this worker's id and token.
typedef WorkersOffice = ({String url, String worker, String token});

/// The office's address and this worker's id and token, from the environment.
WorkersOffice workersOfficeEnv(Map<String, String> env) {
  final missing = [
    for (final k in _envKeys)
      if ((env[k] ?? '').isEmpty) k,
  ];
  if (missing.isNotEmpty) {
    throw WorkersError(
      "${missing.join(', ')} ${missing.length == 1 ? "isn't" : "aren't"} set. office-workers only works inside Agent Office, "
      "from a worker's terminal.",
    );
  }
  return (
    url: env['AGENT_OFFICE_HOOK_URL']!.replaceFirst(RegExp(r'/+$'), ''),
    worker: env['AGENT_OFFICE_WORKER_ID']!,
    token: env['AGENT_OFFICE_HOOK_TOKEN']!,
  );
}

/// An HTTP request to the office.
typedef WorkersRequest = ({String method, Uri url, Map<String, String> headers, String? body, Duration timeout});

/// The HTTP request for one of the office's worker calls: list, hire, home, tell or pr.
WorkersRequest buildWorkersRequest(String what, WorkersOffice office, [Map<String, Object?>? body]) {
  final url = Uri.parse(
    '${office.url}/office/workers${_paths[what]}',
  ).replace(queryParameters: {'worker': office.worker});
  final headers = {'authorization': 'Bearer ${office.token}'};
  if (what == 'list') return (method: 'GET', url: url, headers: headers, body: null, timeout: _timeouts['list']!);
  return (
    method: 'POST',
    url: url,
    headers: {...headers, 'content-type': 'application/json'},
    body: jsonEncode(body ?? const {}),
    timeout: _timeouts[what]!,
  );
}

/// Why the office turned a request down, in words.
String workersRefusal(int status, Object? body) {
  final said = body is Map && body['error'] is String ? body['error'] as String : '';
  if (status == 401) {
    return "The office didn't accept this worker's token (401)${said.isNotEmpty ? ': $said' : ''}. Is this a worker's terminal that's still running?";
  }
  if (status == 404 && said.isEmpty) {
    return "The office doesn't know office-workers (404): it's running an older Agent Office than this command. Restart or upgrade it.";
  }
  if (status == 405) {
    return "The office doesn't know this one yet (405): it's running an older Agent Office than this command. Restart or upgrade it.";
  }
  return said.isNotEmpty ? said : 'The office said no ($status).';
}

/// What the office answered: its status and JSON body.
typedef WorkersResponse = ({int status, Object? body});

/// Sends a request: over HTTP normally, faked in tests.
typedef WorkersSend = Future<WorkersResponse> Function(WorkersRequest req);

/// Sends the request, retrying for a few seconds while nothing's listening (the office restarting).
Future<WorkersResponse> _httpSend(WorkersRequest req) async {
  final until = DateTime.now().add(_retry);
  while (true) {
    final client = HttpClient()..connectionTimeout = req.timeout;
    try {
      final r = await client.openUrl(req.method, req.url).timeout(req.timeout);
      req.headers.forEach(r.headers.set);
      if (req.body != null) r.add(utf8.encode(req.body!));
      final res = await r.close().timeout(req.timeout);
      final text = await res.transform(utf8.decoder).join().timeout(req.timeout);
      Object? body;
      try {
        body = text.isEmpty ? const <String, Object?>{} : jsonDecode(text);
      } catch (_) {
        body = {'error': text.length > 300 ? text.substring(0, 300) : text};
      }
      return (status: res.statusCode, body: body);
    } on SocketException catch (e) {
      final refused = const {61, 111, 10061}.contains(e.osError?.errorCode);
      if (refused && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      throw WorkersError(
        "Couldn't reach the office at ${req.url.origin} (${refused ? 'ECONNREFUSED' : e.message}). Is it running?",
      );
    } on TimeoutException {
      throw WorkersError("Couldn't reach the office at ${req.url.origin} (timed out). Is it running?");
    } finally {
      client.close(force: true);
    }
  }
}

/// What a command needs from the world: the environment and a way to reach the office.
typedef WorkersIo = ({Map<String, String> env, WorkersSend send});

/// Makes one call to the office; resolves to what it answered, or throws with why it said no.
Future<Map<String, Object?>> callOffice(String what, Map<String, Object?>? body, WorkersIo io) async {
  final res = await io.send(buildWorkersRequest(what, workersOfficeEnv(io.env), body));
  if (res.status < 200 || res.status >= 300) throw WorkersError(workersRefusal(res.status, res.body));
  final b = res.body;
  return b is Map ? Map<String, Object?>.from(b) : const {};
}

String _n(Object? v) => v is num && v == v.truncate() ? '${v.toInt()}' : '$v';

Map _map(Object? v) => v is Map ? v : const {};

List _list(Object? v) => v is List ? v : const [];

bool _set(Object? v) => v != null && v != '' && v != false;

/// One worker, in a line.
String formatWorker(Map w) {
  final tags = [
    if (w['you'] == true) 'you',
    if (_set(w['board'])) '${w['board']}',
    if (w['meeting'] == true) 'meeting',
    if (w['kind'] == 'shell') 'shell' else if (_set(w['provider'])) '${w['provider']}',
  ];
  final parts = ['${w['name']}${tags.isNotEmpty ? ' (${tags.join(', ')})' : ''}', '${w['status']}', '${w['desk']}'];
  final wt = w['worktree'];
  if (wt is Map) {
    parts.add('branch ${wt['branch']}${wt['deleted'] == true ? ', worktree deleted: rebuild it at its desk' : ''}');
  }
  final repos = _list(w['repos']);
  if (repos.isNotEmpty) parts.add('also in ${repos.map((r) => _map(r)['name']).join(', ')}');
  final pr = w['pr'];
  if (pr is Map) {
    parts.add('PR #${_n(pr['number'])} ${pr['state']}${_set(pr['title']) ? ' “${pr['title']}”' : ''}');
  }
  final viewers = _list(w['viewers']);
  if (w['merged'] == true) {
    parts.add(_set(w['staying']) ? 'landed, staying: ${w['staying']}' : 'landed: free to go home');
  } else if (viewers.isNotEmpty) {
    parts.add('watched by ${viewers.join(', ')}');
  }
  if (_set(w['task'])) parts.add('${w['task']}');
  return '${w['id']}  ${parts.join(' · ')}';
}

/// Everyone on the floor, as the office lists them.
String formatWorkers(Object? view) {
  final v = _map(view);
  final workers = [for (final w in _list(v['workers'])) _map(w)];
  final f = v['floor'];
  final floor = f is Map ? '${f['name']}${_set(f['repo']) ? ' (${f['repo']})' : ''}' : 'this floor';
  final head =
      '${workers.length} worker${workers.length == 1 ? '' : 's'} on $floor'
      '${_set(v['freeDesk']) ? '' : ' · no desk free'}${_set(v['hiringPaused']) ? ' · hiring paused: ${v['hiringPaused']}' : ''}'
      ' · go home once merged is ${v['leaveOnMerge'] == true ? 'on' : 'off'}';
  return [head, ...workers.map(formatWorker)].join('\n');
}

/// How sending home went, a line per worker.
String formatHome(Object? answer, bool merged) {
  final results = [for (final r in _list(_map(answer)['results'])) _map(r)];
  if (results.isEmpty) return merged ? "Nobody's pull request has merged: nobody to send home." : 'Nobody went home.';
  return results
      .map((r) {
        if (_set(r['skipped'])) return '– ${r['worker']} stayed: ${r['skipped']}';
        if (r['went'] != true) return '✗ ${r['worker']}: ${r['error']}';
        return '✓ ${r['worker']} went home${_set(r['note']) ? ' — ${r['note']}' : ''}${_set(r['error']) ? ' — ${r['error']}' : ''}';
      })
      .join('\n');
}

/// Whose pull request is whose now, after `pr` said so.
String formatLinked(Object? answer) {
  final w = _map(_map(answer)['worker']);
  final pr = w['pr'];
  if (pr is! Map) return '${w['name']} has no pull request now.';
  final landed = w['merged'] == true
      ? (_set(w['staying']) ? ' · landed, staying: ${w['staying']}' : ' · landed: free to go home')
      : '';
  return '${w['name']}: PR #${_n(pr['number'])} ${pr['state']}${_set(pr['title']) ? ' “${pr['title']}”' : ''}$landed';
}

// --- MCP ------------------------------------------------------------------------------------------

/// The MCP protocol versions this server speaks; it answers in the client's when it knows it.
const _mcpVersions = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

const _workerNote = 'A worker is named by its name (e.g. "Mochi") or its id, as list_workers shows them.';

final List<Map<String, Object?>> mcpTools = [
  {
    'name': 'list_workers',
    'title': 'List workers',
    'description':
        "Lists the coding agents (the office's workers) at the desks on this Agent Office floor, and shells: each one's id, name, status, desk, task, git worktree branch and pull request "
        '(pr; a worker that opened one the office does not show here needs link_pr). '
        'merged: true means a pull request of its merged and none is open: its work landed and it can go home. staying says why the office would not send it home by itself yet '
        '(still working, someone has its terminal open, a board agent...). worktree.deleted: true means its folder was deleted outside the office, so it cannot start until a person rebuilds it at its desk. you: true is you.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
    'annotations': {'readOnlyHint': true, 'openWorldHint': false},
  },
  {
    'name': 'hire_worker',
    'title': 'Hire a worker',
    'description':
        'Hires a new coding agent (a worker) at a free desk in Agent Office to do a task. It starts right away, in its own git worktree on a fresh branch unless worktree is false, '
        'and knows nothing but the prompt: make it complete (what to change and where, how to check it, and to open a pull request).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'prompt': {'type': 'string', 'description': 'The task, complete on its own.'},
        'provider': {
          'type': 'string',
          'description':
              "Which agent runs it (claude, codex, opencode...; list_workers' providers). Default: the office's.",
        },
        'model': {'type': 'string', 'description': "A model for it, instead of the provider's default."},
        'effort': {'type': 'string', 'enum': efforts, 'description': 'Reasoning effort, for agents that take one.'},
        'worktree': {
          'type': 'boolean',
          'description': 'Its own git worktree and branch (default true in a git checkout).',
        },
        'desk': {'type': 'string', 'description': 'A desk or bean bag id (desk-3). Default: the next free one.'},
        'issue': {
          'type': 'integer',
          'minimum': 1,
          'description': 'The GitHub issue it works on, assigned when it starts.',
        },
      },
      'required': ['prompt'],
      'additionalProperties': false,
    },
    'annotations': {'destructiveHint': false, 'openWorldHint': false},
  },
  {
    'name': 'send_home',
    'title': 'Send workers home',
    'description':
        "Sends agents (the office's workers) home: each one stops and leaves its desk. With cleanup auto (the default) its git worktree and branch are deleted too, "
        "unless they hold work that isn't on GitHub (uncommitted changes, or commits no remote has; what a merged pull request delivered counts as on GitHub): "
        'then they are kept and the result says why. Name the workers, or pass merged: true for everyone whose pull request merged, is at rest and has nobody watching '
        "(the office's go-home-once-merged rule); the result lists who stayed and why. cleanup keep keeps the worktree and branch, worktree deletes just the worktree, "
        'and all deletes both even when that loses work: use all only when the user asked for it. A worktree kept this way stays after its worker has gone '
        '(git worktree remove and git branch -D delete it, if the user wants that work thrown away). You cannot send yourself home. '
        '$_workerNote',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'workers': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'The workers to send home, by name or id.',
        },
        'merged': {'type': 'boolean', 'description': 'Everyone whose pull request merged, instead of naming them.'},
        'cleanup': {
          'type': 'string',
          'enum': cleanups,
          'description': 'What becomes of their worktrees and branches (default auto).',
        },
      },
      'additionalProperties': false,
    },
    'annotations': {'destructiveHint': true, 'idempotentHint': false, 'openWorldHint': false},
  },
  {
    'name': 'tell_worker',
    'title': 'Tell a worker',
    'description':
        "Types a message into another agent's (worker's) terminal as its next prompt; one that stopped starts again with it. $_workerNote",
    'inputSchema': {
      'type': 'object',
      'properties': {
        'worker': {'type': 'string', 'description': 'The worker, by name or id.'},
        'prompt': {'type': 'string', 'description': 'What to tell it.'},
      },
      'required': ['worker', 'prompt'],
      'additionalProperties': false,
    },
    'annotations': {'destructiveHint': false, 'openWorldHint': false},
  },
  {
    'name': 'link_pr',
    'title': "Say which pull request is a worker's",
    'description':
        "Says which pull request is a worker's, so its desk and list_workers show where its work stands (open, or merged: free to go home) instead of only ready or done. "
        'The office knows a pull request by itself when it was opened from the desk, from the branch the office gave the worker, by a queue task, or by a Claude Code worker running gh pr create. '
        'Use this for the others: a worker in the main checkout that pushed a branch of its own, or an agent whose pull request list_workers does not show. Match a worker to its pull request by what it '
        "was asked to do (its task, the issue it names) and gh pr list, and leave out one you can't match. The pull request must be open, or merged recently, in this floor's repository. "
        'With go home once merged on (leaveOnMerge), a worker whose linked pull request merged is sent home. unlink: true takes a wrong one off again. worker defaults to you. '
        '$_workerNote',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'pr': {'type': 'integer', 'minimum': 1, 'description': "The pull request's number."},
        'worker': {'type': 'string', 'description': 'Whose it is, by name or id. Default: you.'},
        'unlink': {'type': 'boolean', 'description': 'Take the pull request off the worker, instead of giving pr.'},
      },
      'additionalProperties': false,
    },
    'annotations': {'destructiveHint': false, 'idempotentHint': true, 'openWorldHint': false},
  },
];

const _instructions =
    "You work in Agent Office, where coding agents (the office's workers) sit at desks, each usually in its own git worktree and branch. These tools are the way to see and manage "
    'the other agents: whenever you are asked about the agents or workers (who is working on what, whose pull request merged, hiring one, sending them home), use them, '
    "rather than looking for the agents with git, ps or HTTP calls. list_workers says where each one's pull request stands (merged: true means it merged), hire_worker "
    'puts a new agent to work, send_home sends agents home and deletes their worktrees and branches, tell_worker gives one a prompt, and link_pr says which pull request is a '
    "worker's when list_workers does not show it. Everyone in the office sees who did what. "
    'The office-workers command on your PATH does the same from a shell. '
    "To build the app on Codemagic, when this floor has one set up, use the agent-office codemagic command on your PATH "
    '(workflows, build "<workflow>" [--branch <b>] [--wait], status <id>; see agent-office codemagic --help): the office holds the token. '
    'Builds cost minutes: start one only when your task asks for it, push your branch first, and say what you started with its link.';

/// Runs a tool; resolves to its text, and whether nothing it was asked came off, or throws with why it failed.
Future<({String text, bool isError})> _runTool(String name, Object? args, WorkersIo io) async {
  final a = args is Map ? Map<String, Object?>.from(args) : <String, Object?>{};
  const indent = JsonEncoder.withIndent(' ');
  switch (name) {
    case 'list_workers':
      return (text: indent.convert(await callOffice('list', null, io)), isError: false);
    case 'hire_worker':
      final answer = await callOffice('hire', a, io);
      final w = _map(answer['worker']);
      final wt = w['worktree'];
      return (
        text:
            'Hired ${w['name']} at ${w['desk']}${wt is Map ? ' on branch ${wt['branch']}' : ''} (id ${w['id']}).\n${indent.convert(w)}',
        isError: false,
      );
    case 'send_home':
      final answer = await callOffice('home', a, io);
      final results = [for (final r in _list(answer['results'])) _map(r)];
      return (
        text: formatHome(answer, a['merged'] == true),
        isError: results.any((r) => _set(r['error'])) && !results.any((r) => r['went'] == true || _set(r['skipped'])),
      );
    case 'tell_worker':
      final answer = await callOffice('tell', a, io);
      return (text: 'Told ${_map(answer['worker'])['name'] ?? a['worker']}.', isError: false);
    case 'link_pr':
      return (text: formatLinked(await callOffice('pr', a, io)), isError: false);
  }
  throw WorkersError('Unknown tool: $name');
}

/// What the MCP server answers one JSON-RPC message with; null for a notification.
Future<Map<String, Object?>?> handleMcp(Object? msg, WorkersIo io) async {
  if (msg is! Map || msg['jsonrpc'] != '2.0' || msg['method'] is! String) {
    // A response to something we never asked: nothing to say.
    if (msg is Map && msg.containsKey('id') && !msg.containsKey('method')) return null;
    return {
      'jsonrpc': '2.0',
      'id': msg is Map ? msg['id'] : null,
      'error': {'code': -32600, 'message': 'Invalid request'},
    };
  }
  if (!msg.containsKey('id')) return null;
  final id = msg['id'];
  Map<String, Object?> ok(Object? result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
  final params = _map(msg['params']);
  switch (msg['method']) {
    case 'initialize':
      final asked = params['protocolVersion'];
      return ok({
        'protocolVersion': _mcpVersions.contains(asked) ? asked : _mcpVersions.first,
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {'name': 'agent-office', 'title': 'Agent Office', 'version': '1.0.0'},
        'instructions': _instructions,
      });
    case 'ping':
      return ok(const <String, Object?>{});
    case 'tools/list':
      return ok({'tools': mcpTools});
    case 'tools/call':
      final name = params['name'];
      if (!mcpTools.any((t) => t['name'] == name)) {
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32602, 'message': 'Unknown tool: $name'},
        };
      }
      try {
        final r = await _runTool(name as String, params['arguments'], io);
        return ok({
          'content': [
            {'type': 'text', 'text': r.text},
          ],
          if (r.isError) 'isError': true,
        });
      } catch (e) {
        return ok({
          'content': [
            {'type': 'text', 'text': e is WorkersError ? e.message : '$e'},
          ],
          'isError': true,
        });
      }
    default:
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'Method not found: ${msg['method']}'},
      };
  }
}

/// Serves MCP on stdio: a JSON-RPC message per line each way. Completes when [input] closes.
Future<void> serveMcp(WorkersIo io, Stream<List<int>> input, void Function(String line) write) async {
  final pending = <Future<void>>{};
  void reply(Object? res) {
    if (res != null) write(jsonEncode(res));
  }

  await for (final line in input.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    Object? msg;
    try {
      msg = jsonDecode(line);
    } catch (_) {
      reply({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      });
      continue;
    }
    Future<Map<String, Object?>?> one(Object? m) => handleMcp(m, io).catchError(
      (Object e) => <String, Object?>{
        'jsonrpc': '2.0',
        'id': m is Map ? m['id'] : null,
        'error': {'code': -32603, 'message': '$e'},
      },
    );
    // A batch, from an older client.
    final Future<Object?> answer = msg is List
        ? Future.wait(msg.map(one)).then((all) {
            final some = all.whereType<Map<String, Object?>>().toList();
            return some.isEmpty ? null : some;
          })
        : one(msg);
    late final Future<void> p;
    p = answer.then(reply).whenComplete(() => pending.remove(p));
    pending.add(p);
  }
  await Future.wait(List.of(pending));
}

/// Runs `office-workers …` ([argv] is what follows `workers`); resolves to its exit code.
Future<int> runWorkersCommand(
  List<String> argv, {
  Map<String, String>? env,
  Stream<List<int>>? input,
  bool? inputIsTerminal,
  WorkersSend? send,
  void Function(String line)? out,
  void Function(String line)? err,
}) async {
  final io = (env: env ?? Platform.environment, send: send ?? _httpSend);
  final void Function(String) say = out ?? stdout.writeln;
  final void Function(String) complain = err ?? stderr.writeln;
  try {
    final cmd = parseWorkersArgs(argv);
    final what = cmd['cmd'];
    if (what == 'help') {
      say(workersUsage);
      return 0;
    }
    // Starts even without the office's variables, so the agent hears why each tool fails.
    if (what == 'mcp') {
      await serveMcp(io, input ?? stdin, say);
      return 0;
    }
    workersOfficeEnv(io.env);
    final json = cmd['json'] == true;
    Future<String> prompt() async {
      if (cmd['prompt'] != null) return '${cmd['prompt']}';
      final tty = inputIsTerminal ?? (input == null && stdin.hasTerminal);
      if (tty) {
        throw WorkersUsageError(
          "Give the prompt on stdin (office-workers $what … <<'EOF' … EOF) or with --prompt \"…\"",
        );
      }
      return (input ?? stdin).transform(const Utf8Decoder(allowMalformed: true)).join();
    }

    const pretty = JsonEncoder.withIndent('  ');
    switch (what) {
      case 'list':
        final view = await callOffice('list', null, io);
        say(json ? pretty.convert(view) : formatWorkers(view));
        return 0;
      case 'home':
        final merged = cmd['merged'] == true;
        final answer = await callOffice('home', {
          if (merged) 'merged': true else 'workers': cmd['workers'],
          'cleanup': ?cmd['cleanup'],
        }, io);
        say(json ? pretty.convert(answer) : formatHome(answer, merged));
        return _list(answer['results']).any((r) => _set(_map(r)['error'])) ? 1 : 0;
      case 'tell':
        final text = (await prompt()).trim();
        if (text.isEmpty) throw WorkersUsageError('The prompt is empty');
        final answer = await callOffice('tell', {'worker': cmd['worker'], 'prompt': text}, io);
        complain('Told ${_map(answer['worker'])['name'] ?? cmd['worker']}.');
        return 0;
      case 'pr':
        final ask = {
          for (final e in cmd.entries)
            if (e.key != 'cmd' && e.key != 'json') e.key: e.value,
        };
        final answer = await callOffice('pr', ask, io);
        say(json ? pretty.convert(answer['worker']) : formatLinked(answer));
        return 0;
    }
    final body = {
      for (final e in cmd.entries)
        if (e.key != 'cmd' && e.key != 'json') e.key: e.value,
    };
    body['prompt'] = (await prompt()).trim();
    if (body['prompt'] == '') throw WorkersUsageError('The new worker needs a task: pipe it in or pass --prompt "…"');
    final answer = await callOffice('hire', body, io);
    final w = _map(answer['worker']);
    if (json) {
      say(pretty.convert(w));
    } else {
      say('${w['id'] ?? ''}');
      final wt = w['worktree'];
      complain('Hired ${w['name']} at ${w['desk']}${wt is Map ? ' on branch ${wt['branch']}' : ''}.');
    }
    return 0;
  } on WorkersUsageError catch (e) {
    complain('office-workers: ${e.message}');
    complain('\n$workersUsage');
    return 2;
  } on WorkersError catch (e) {
    complain('office-workers: ${e.message}');
    return 1;
  } catch (e) {
    complain('office-workers: $e');
    return 1;
  }
}
