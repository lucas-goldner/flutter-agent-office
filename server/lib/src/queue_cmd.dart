// `agent-office queue`: the task queue from inside Agent Office, for the agents standing by the
// boards (see stations.dart). The office puts the `agent-office` command on their PATH and gives
// them their own address and token in AGENT_OFFICE_HOOK_URL, AGENT_OFFICE_WORKER_ID and
// AGENT_OFFICE_HOOK_TOKEN; this talks to the /office/queue endpoint with them. Port of upstream's
// bin/office-queue.js.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const queueUsage = '''Usage:
  agent-office queue list                                  what's on the queue: id, status, title, worker, PR
  agent-office queue add --title "…" [--issue 12] <<'EOF'  add a task, its prompt on stdin (or --prompt "…");
  …the prompt…                                             prints the new task's id
  EOF
  agent-office queue remove <id>                           take a waiting task off''';

/// A mistake in how the command was called: the usage is shown with it.
class QueueUsageError implements Exception {
  QueueUsageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Something that went wrong talking to the office.
class QueueError implements Exception {
  QueueError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _envKeys = ['AGENT_OFFICE_HOOK_URL', 'AGENT_OFFICE_WORKER_ID', 'AGENT_OFFICE_HOOK_TOKEN'];

/// How long the office may take to come back when it's restarting (a dev reload, an upgrade).
const _retry = Duration(seconds: 6);
const _timeout = Duration(seconds: 15);

/// What the command line asks for.
sealed class QueueCommand {
  const QueueCommand();
}

class QueueHelp extends QueueCommand {
  const QueueHelp();
  @override
  bool operator ==(Object other) => other is QueueHelp;
  @override
  int get hashCode => 0;
}

class QueueList extends QueueCommand {
  const QueueList();
  @override
  bool operator ==(Object other) => other is QueueList;
  @override
  int get hashCode => 1;
}

class QueueRemove extends QueueCommand {
  const QueueRemove(this.id);
  final String id;
  @override
  bool operator ==(Object other) => other is QueueRemove && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class QueueAdd extends QueueCommand {
  const QueueAdd({required this.title, this.issue, this.prompt});
  final String title;
  final int? issue;

  /// Given with --prompt; otherwise it comes in on stdin.
  final String? prompt;
  @override
  bool operator ==(Object other) =>
      other is QueueAdd && other.title == title && other.issue == issue && other.prompt == prompt;
  @override
  int get hashCode => Object.hash(title, issue, prompt);
  @override
  String toString() => 'QueueAdd($title, $issue, $prompt)';
}

/// [argv] is what follows `queue`.
QueueCommand parseQueueArgs(List<String> argv) {
  bool help(String? a) => a == '-h' || a == '--help';
  if (argv.isEmpty || argv[0] == 'help' || help(argv[0]) || (argv.length > 1 && help(argv[1]))) {
    return const QueueHelp();
  }
  final cmd = argv[0];
  final rest = argv.sublist(1);
  if (cmd == 'list' || cmd == 'ls') {
    if (rest.isNotEmpty) throw QueueUsageError('list takes no arguments (got ${rest.join(' ')})');
    return const QueueList();
  }
  if (cmd == 'remove' || cmd == 'rm') {
    if (rest.length != 1 || rest[0].startsWith('-')) {
      throw QueueUsageError('remove takes one task id, e.g. agent-office queue remove 3f9c2a1b7d4e');
    }
    return QueueRemove(rest[0]);
  }
  if (cmd != 'add') throw QueueUsageError('Unknown command: $cmd');
  String? title, prompt;
  int? issue;
  for (var i = 0; i < rest.length; i++) {
    final arg = rest[i];
    final eq = arg.indexOf('=');
    final flag = arg.startsWith('--') && eq > 0 ? arg.substring(0, eq) : arg;
    if (flag != '--title' && flag != '--issue' && flag != '--prompt') {
      throw QueueUsageError(
        arg.startsWith('-')
            ? 'Unknown option for add: $flag'
            : 'Unexpected argument: $arg (quote the title, and give the prompt on stdin or with --prompt)',
      );
    }
    String value;
    if (flag != arg) {
      value = arg.substring(eq + 1);
    } else if (i + 1 < rest.length) {
      value = rest[++i];
    } else {
      throw QueueUsageError('$flag needs a value');
    }
    if (flag == '--title') {
      title = value.trim();
    } else if (flag == '--prompt') {
      prompt = value;
    } else {
      final n = RegExp(r'^#?(\d+)$').firstMatch(value.trim());
      final number = n == null ? null : int.tryParse(n.group(1)!);
      if (number == null || number < 1) {
        throw QueueUsageError('--issue takes an issue number, e.g. --issue 12 (got $value)');
      }
      issue = number;
    }
  }
  if (title == null || title.isEmpty) {
    throw QueueUsageError('Give the task a --title, e.g. agent-office queue add --title "Fix the login redirect"');
  }
  return QueueAdd(title: title, issue: issue, prompt: prompt);
}

/// The office's address and this agent's id and token.
typedef QueueOffice = ({String url, String worker, String token});

/// The office's address and this agent's name and token, from the environment.
QueueOffice queueOfficeEnv(Map<String, String> env) {
  final missing = [
    for (final k in _envKeys)
      if ((env[k] ?? '').isEmpty) k,
  ];
  if (missing.isNotEmpty) {
    throw QueueError(
      "${missing.join(', ')} ${missing.length == 1 ? "isn't" : "aren't"} set. agent-office queue only works inside Agent Office, "
      'from the terminal of an agent standing by one of the boards.',
    );
  }
  return (
    url: env['AGENT_OFFICE_HOOK_URL']!.replaceFirst(RegExp(r'/+$'), ''),
    worker: env['AGENT_OFFICE_WORKER_ID']!,
    token: env['AGENT_OFFICE_HOOK_TOKEN']!,
  );
}

/// An HTTP request to the office.
typedef QueueRequest = ({String method, Uri url, Map<String, String> headers, String? body});

/// The HTTP request for a parsed command (anything but help). [prompt] is the task's prompt for an
/// add that didn't give --prompt: what came in on stdin.
QueueRequest buildQueueRequest(QueueCommand cmd, QueueOffice office, [String? prompt]) {
  final base = Uri.parse('${office.url}/office/queue');
  Uri url(Map<String, String> q) => base.replace(queryParameters: {'worker': office.worker, ...q});
  final headers = {'authorization': 'Bearer ${office.token}'};
  switch (cmd) {
    case QueueList():
      return (method: 'GET', url: url({}), headers: headers, body: null);
    case QueueRemove(:final id):
      return (method: 'DELETE', url: url({'task': id}), headers: headers, body: null);
    case QueueAdd(:final title, :final issue):
      final text = (cmd.prompt ?? prompt ?? '').replaceAll(RegExp(r'\r\n?'), '\n').trim();
      if (text.isEmpty) {
        throw QueueUsageError(
          "The task needs a prompt: pipe it in (agent-office queue add --title \"…\" <<'EOF' … EOF) or pass --prompt \"…\"",
        );
      }
      return (
        method: 'POST',
        url: url({}),
        headers: {...headers, 'content-type': 'application/json'},
        body: jsonEncode({'title': title, 'prompt': text, 'issue': ?issue}),
      );
    case QueueHelp():
      throw ArgumentError('No request for help');
  }
}

/// The queue as the office returns it, one line per task.
String formatQueue(Object? view) {
  final v = view is Map ? view : const {};
  final tasks = [
    for (final t in v['tasks'] is List ? v['tasks'] as List : const [])
      if (t is Map) t,
  ];
  final max = v['maxWorkers'];
  final limit = max is num ? ' · up to ${_n(max)} at a time' : '';
  if (tasks.isEmpty) return 'The queue is empty$limit.';
  final lines = ['${tasks.length} task${tasks.length == 1 ? '' : 's'}$limit'];
  String status(Map t) {
    final o = t['outcome'];
    return t['status'] == 'done' && o != null && o != '' && o != 'done' ? 'done ($o)' : '${t['status'] ?? '?'}';
  }

  final width = tasks.map((t) => status(t).length).reduce((a, b) => a > b ? a : b);
  for (final t in tasks) {
    final issue = t['issue'];
    final parts = ['${t['title'] ?? ''}${issue != null && issue != 0 ? ' (issue #${_n(issue)})' : ''}'];
    final worker = t['worker'];
    if (worker != null && worker != '') {
      final branch = t['branch'];
      parts.add('worker $worker${branch != null && branch != '' ? ' on $branch' : ''}');
    }
    final pr = t['pr'];
    if (pr is Map) {
      final state = pr['state'];
      parts.add(
        'PR #${_n(pr['number'])}${state != null && state != '' ? ' ${'$state'.toLowerCase()}' : ''} ${pr['url']}',
      );
    }
    final error = t['error'];
    if (error != null && error != '') parts.add('error: $error');
    lines.add('${t['id']}  ${status(t).padRight(width)}  ${parts.join(' · ')}');
  }
  return lines.join('\n');
}

String _n(Object? v) => v is num && v == v.truncate() ? '${v.toInt()}' : '$v';

/// Why the office turned a request down, in words.
String queueRefusal(int status, Object? body) {
  final said = body is Map && body['error'] is String ? body['error'] as String : '';
  if (status == 401) {
    return "The office didn't accept this agent's token (401)${said.isNotEmpty ? ': $said' : ''}. Is this the terminal of a board agent that's still running?";
  }
  if (status == 403) {
    return 'The office said no (403): ${said.isNotEmpty ? said : 'only the agents standing by the boards can use the queue'}.';
  }
  return 'The office said no ($status)${said.isNotEmpty ? ': $said' : ''}.';
}

/// What the office answered: its status and JSON body.
typedef QueueResponse = ({int status, Object? body});

/// Sends a request: over HTTP normally, faked in tests.
typedef QueueSend = Future<QueueResponse> Function(QueueRequest req);

/// Sends the request, retrying for a few seconds while nothing's listening (the office restarting).
Future<QueueResponse> _httpSend(QueueRequest req) async {
  final until = DateTime.now().add(_retry);
  while (true) {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final r = await client.openUrl(req.method, req.url).timeout(_timeout);
      req.headers.forEach(r.headers.set);
      if (req.body != null) r.add(utf8.encode(req.body!));
      final res = await r.close().timeout(_timeout);
      final text = await res.transform(utf8.decoder).join().timeout(_timeout);
      Object? body;
      try {
        body = text.isEmpty ? const {} : jsonDecode(text);
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
      throw QueueError(
        "Couldn't reach the office at ${req.url.origin} (${refused ? 'ECONNREFUSED' : e.message}). Is it running?",
      );
    } on TimeoutException {
      throw QueueError("Couldn't reach the office at ${req.url.origin} (timed out). Is it running?");
    } finally {
      client.close(force: true);
    }
  }
}

/// Runs `agent-office queue …` ([argv] is what follows `queue`); resolves to its exit code.
Future<int> runQueueCommand(
  List<String> argv, {
  Map<String, String>? env,
  Stream<List<int>>? input,
  bool? inputIsTerminal,
  QueueSend? send,
  void Function(String line)? out,
  void Function(String line)? err,
}) async {
  final environment = env ?? Platform.environment;
  final say = out ?? stdout.writeln;
  final complain = err ?? stderr.writeln;
  try {
    final cmd = parseQueueArgs(argv);
    if (cmd is QueueHelp) {
      say(queueUsage);
      return 0;
    }
    final office = queueOfficeEnv(environment);
    String? prompt;
    if (cmd is QueueAdd && cmd.prompt == null) {
      final tty = inputIsTerminal ?? (input == null && stdin.hasTerminal);
      if (tty) {
        throw QueueUsageError(
          "The task needs a prompt: pipe it in (agent-office queue add --title \"…\" <<'EOF' … EOF) or pass --prompt \"…\"",
        );
      }
      prompt = await (input ?? stdin).transform(const Utf8Decoder(allowMalformed: true)).join();
    }
    final req = buildQueueRequest(cmd, office, prompt);
    final res = await (send ?? _httpSend)(req);
    if (res.status < 200 || res.status >= 300) {
      complain('agent-office queue: ${queueRefusal(res.status, res.body)}');
      return 1;
    }
    switch (cmd) {
      case QueueList():
        say(formatQueue(res.body));
      case QueueRemove(:final id):
        say('Took $id off the queue.');
      case QueueAdd(:final title, :final issue):
        final body = res.body;
        final task = body is Map && body['task'] is Map ? body['task'] as Map : const {};
        say('${task['id'] ?? ''}');
        complain(
          'Queued “${task['title'] ?? title}” (${task['status'] ?? 'queued'}${issue != null ? ', issue #$issue' : ''}).',
        );
      case QueueHelp():
        break;
    }
    return 0;
  } on QueueUsageError catch (e) {
    complain('agent-office queue: ${e.message}');
    complain('\n$queueUsage');
    return 2;
  } on QueueError catch (e) {
    complain('agent-office queue: ${e.message}');
    return 1;
  } catch (e) {
    complain('agent-office queue: $e');
    return 1;
  }
}
