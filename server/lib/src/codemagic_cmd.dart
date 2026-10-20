// `agent-office codemagic`: a worker's floor's Codemagic builds from its terminal. The
// workflows it can start, starting one on a branch (this worktree's, unless told), and a build's
// status with its artifacts' download links, waiting for it to end with --wait. It talks to the
// office's /office/codemagic endpoint with the worker's own AGENT_OFFICE_HOOK_URL,
// AGENT_OFFICE_WORKER_ID and AGENT_OFFICE_HOOK_TOKEN; the Codemagic token stays with the office.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'queue_cmd.dart' show QueueError, QueueRequest, QueueSend, QueueUsageError, officeSend, queueOfficeEnv;

const codemagicUsage = '''Usage:
  agent-office codemagic workflows                       the floor's app and the workflows you can start
  agent-office codemagic build "iOS dev" [--branch <b>] [--var KEY=VALUE …] [--wait]
                                                         start one (on this worktree's branch unless
                                                         --branch); --wait follows it to the end
  agent-office codemagic status <build id or #number> [--wait]
                                                         how it's doing, its page and download links''';

sealed class CodemagicCommand {
  const CodemagicCommand();
}

class CodemagicHelp extends CodemagicCommand {
  const CodemagicHelp();
}

class CodemagicWorkflowsCmd extends CodemagicCommand {
  const CodemagicWorkflowsCmd();
}

class CodemagicBuildCmdLine extends CodemagicCommand {
  const CodemagicBuildCmdLine(this.workflow, {this.branch, this.variables = const {}, this.wait = false});
  final String workflow;
  final String? branch;
  final Map<String, String> variables;
  final bool wait;
}

class CodemagicStatusCmd extends CodemagicCommand {
  const CodemagicStatusCmd(this.build, {this.wait = false});
  final String build;
  final bool wait;
}

/// Reads `agent-office codemagic …` ([argv] is what follows `codemagic`).
CodemagicCommand parseCodemagicArgs(List<String> argv) {
  if (argv.isEmpty || const ['help', '-h', '--help'].contains(argv.first)) return const CodemagicHelp();
  final rest = argv.sublist(1);
  switch (argv.first) {
    case 'workflows':
      return const CodemagicWorkflowsCmd();
    case 'build':
      if (rest.isEmpty || rest.first.startsWith('-')) {
        throw QueueUsageError('Name the workflow: agent-office codemagic build "iOS dev"');
      }
      String? branch;
      var wait = false;
      final vars = <String, String>{};
      for (var i = 1; i < rest.length; i++) {
        switch (rest[i]) {
          case '--branch' || '-b':
            if (i + 1 >= rest.length) throw QueueUsageError('--branch needs a value');
            branch = rest[++i];
          case '--var' || '-v':
            if (i + 1 >= rest.length) throw QueueUsageError('--var needs KEY=VALUE');
            final kv = rest[++i];
            final eq = kv.indexOf('=');
            if (eq <= 0) throw QueueUsageError('A variable is KEY=VALUE, not “$kv”');
            vars[kv.substring(0, eq).trim()] = kv.substring(eq + 1);
          case '--wait' || '-w':
            wait = true;
          default:
            throw QueueUsageError('Unknown option ${rest[i]}');
        }
      }
      return CodemagicBuildCmdLine(rest.first, branch: branch, variables: vars, wait: wait);
    case 'status':
      if (rest.isEmpty) throw QueueUsageError('Which build? agent-office codemagic status <build id or #number>');
      return CodemagicStatusCmd(rest.first.replaceFirst('#', ''), wait: rest.contains('--wait') || rest.contains('-w'));
  }
  throw QueueUsageError('Unknown command “${argv.first}”');
}

String _statusLine(Map b) {
  final s = '${b['status'] ?? '?'}';
  final light = s == 'finished'
      ? '🟢'
      : (s == 'failed' || s == 'timeout')
      ? '🔴'
      : (s == 'canceled' || s == 'skipped')
      ? '⚪'
      : '🟡';
  final index = b['index'] is int && (b['index'] as int) > 0 ? ' #${b['index']}' : '';
  return '$light ${b['workflow'] ?? '?'}$index on ${b['branch'] ?? '?'}: $s';
}

/// The build's lines for the terminal: its status, page, and download links.
String formatCodemagicBuild(Object? body) {
  final j = body is Map ? body : const {};
  final b = j['build'] is Map ? j['build'] as Map : const {};
  return [
    _statusLine(b),
    if (b['link'] is String) '   page: ${b['link']}',
    if (b['id'] is String) '   id: ${b['id']}',
    for (final d in j['downloads'] is List ? j['downloads'] as List : const [])
      if (d is Map) '   📦 ${d['name']}: ${d['url']}',
  ].join('\n');
}

/// Runs `agent-office codemagic …`; resolves to its exit code.
Future<int> runCodemagicCommand(
  List<String> argv, {
  Map<String, String>? env,
  QueueSend? send,
  String? Function()? currentBranch,
  Duration pollEvery = const Duration(seconds: 20),
  void Function(String line)? out,
  void Function(String line)? err,
}) async {
  final say = out ?? stdout.writeln;
  final complain = err ?? stderr.writeln;
  try {
    final cmd = parseCodemagicArgs(argv);
    if (cmd is CodemagicHelp) {
      say(codemagicUsage);
      return 0;
    }
    final office = queueOfficeEnv(env ?? Platform.environment);
    final base = Uri.parse('${office.url}/office/codemagic');
    Uri url([Map<String, String> q = const {}]) => base.replace(queryParameters: {'worker': office.worker, ...q});
    final headers = {'authorization': 'Bearer ${office.token}'};
    Future<Object?> call(QueueRequest req) async {
      final res = await (send ?? officeSend)(req);
      if (res.status < 200 || res.status >= 300) {
        final said = res.body is Map && (res.body as Map)['error'] is String
            ? (res.body as Map)['error'] as String
            : '';
        throw QueueError(said.isNotEmpty ? said : 'the office said no (${res.status})');
      }
      return res.body;
    }

    Future<int> follow(String id) async {
      while (true) {
        final body = await call((method: 'GET', url: url({'build': id}), headers: headers, body: null));
        final b = body is Map && body['build'] is Map ? body['build'] as Map : const {};
        final s = '${b['status']}';
        if (const ['finished', 'failed', 'canceled', 'timeout', 'skipped'].contains(s)) {
          say(formatCodemagicBuild(body));
          return s == 'finished' ? 0 : 1;
        }
        say(_statusLine(b));
        await Future<void>.delayed(pollEvery);
      }
    }

    switch (cmd) {
      case CodemagicWorkflowsCmd():
        final j = await call((method: 'GET', url: url(), headers: headers, body: null));
        final m = j is Map ? j : const {};
        say('App: ${m['appName'] ?? m['appId'] ?? '?'}');
        for (final w in m['workflows'] is List ? m['workflows'] as List : const []) {
          if (w is Map) say('  “${w['name'] ?? w['id']}”${w['name'] != null ? '  (${w['id']})' : ''}');
        }
        final builds = m['builds'] is List ? m['builds'] as List : const [];
        if (builds.isNotEmpty) {
          say('Recent builds:');
          for (final b in builds.take(5)) {
            if (b is Map) say('  ${_statusLine(b)}  ${b['id']}');
          }
        }
        return 0;
      case CodemagicBuildCmdLine(:final workflow, :final variables, :final wait):
        final branch = cmd.branch ?? (currentBranch ?? _gitBranch)();
        if (branch == null || branch.isEmpty || branch == 'HEAD') {
          throw QueueUsageError('Say which branch: --branch <name>');
        }
        final body = await call((
          method: 'POST',
          url: url(),
          headers: {...headers, 'content-type': 'application/json'},
          body: jsonEncode({'workflow': workflow, 'branch': branch, if (variables.isNotEmpty) 'variables': variables}),
        ));
        say('Started: ${formatCodemagicBuild(body)}');
        final id = body is Map && body['build'] is Map ? '${(body['build'] as Map)['id']}' : '';
        return wait && id.isNotEmpty ? await follow(id) : 0;
      case CodemagicStatusCmd(:final build, :final wait):
        if (wait) return await follow(build);
        say(
          formatCodemagicBuild(await call((method: 'GET', url: url({'build': build}), headers: headers, body: null))),
        );
        return 0;
      case CodemagicHelp():
        return 0;
    }
  } on QueueUsageError catch (e) {
    complain('agent-office codemagic: ${e.message}\n\n$codemagicUsage');
    return 2;
  } on QueueError catch (e) {
    complain('agent-office codemagic: ${e.message}');
    return 1;
  }
}

String? _gitBranch() {
  try {
    final r = Process.runSync('git', ['rev-parse', '--abbrev-ref', 'HEAD']);
    return r.exitCode == 0 ? (r.stdout as String).trim() : null;
  } catch (_) {
    return null;
  }
}
