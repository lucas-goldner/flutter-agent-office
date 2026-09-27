// The hook helper: `agent-office hook claude <event>` and `agent-office hook codex <event>`.
//
// Claude Code and Codex run a command for each lifecycle hook, with the hook's JSON on stdin; the
// office wants it POSTed to its bridge. Claude's hook command tries curl first (see
// claudeHookCommand) and falls back to this. Codex's always runs this, since it filters the payload
// before it leaves the machine. The office's own executable is always there, unlike curl on
// minimal VPS images.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'codex.dart';

/// Attempts at reaching the office from a Claude hook: it may be restarting.
const hookTries = 6;

/// Wraps [value] in single quotes for a POSIX shell.
String shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

/// The argv that runs the office's own executable: the compiled binary, or under `dart run`
/// (development, tests) the Dart VM with the server's entry point.
List<String> officeCommand() {
  final exe = Platform.resolvedExecutable;
  final name = p.basenameWithoutExtension(exe).toLowerCase();
  if (name != 'dart') return [exe];
  final lib = Isolate.resolvePackageUriSync(Uri.parse('package:agent_office_server/src/hook.dart'));
  final root = lib != null
      ? p.dirname(p.dirname(p.dirname(lib.toFilePath())))
      : p.dirname(p.dirname(p.absolute(Platform.script.toFilePath())));
  return [exe, 'run', p.join(root, 'bin', 'agent_office.dart')];
}

/// The shell command Claude Code runs for a hook [event]: POST stdin to the office with curl, or
/// with the office's own executable where curl is missing. Silent, and never fails the hook.
String claudeHookCommand(String event, {List<String>? office}) {
  final curl =
      'curl -sS -m 3 --retry ${hookTries - 1} --retry-delay 1 --retry-connrefused -X POST -H "Authorization: Bearer \$AGENT_OFFICE_HOOK_TOKEN" -H "Content-Type: application/json" '
      '--data-binary @- "\$AGENT_OFFICE_HOOK_URL/hooks/claude?worker=\$AGENT_OFFICE_WORKER_ID&event=$event"';
  final fallback = [...(office ?? officeCommand()), 'hook', 'claude', event].map(shellQuote).join(' ');
  return 'if [ -z "\$AGENT_OFFICE_WORKER_ID" ] || [ -z "\$AGENT_OFFICE_HOOK_URL" ]; then exit 0; fi; '
      'if command -v curl >/dev/null 2>&1; then $curl >/dev/null 2>&1; '
      'else $fallback >/dev/null 2>&1; fi; true';
}

/// `agent-office hook <claude|codex> <event>` ([args] are what follows `hook`). Reads the hook
/// payload from stdin and forwards it to the office named by AGENT_OFFICE_HOOK_URL. Always exits 0:
/// a hook that fails must not get in the agent's way.
Future<int> runHook(
  List<String> args, {
  Stream<List<int>>? input,
  Map<String, String>? environment,
  IOSink? output,
}) async {
  final env = environment ?? Platform.environment;
  final kind = args.isNotEmpty ? args[0] : '';
  final event = args.length > 1 ? args[1] : '';
  try {
    if (kind == 'claude') {
      await _claudeHook(event, input ?? stdin, env);
    } else if (kind == 'codex') {
      if (await _codexHook(event, input ?? stdin, env)) (output ?? stdout).write('{}');
    }
    await (output ?? stdout).flush();
  } catch (_) {
    // Nothing to report to: the agent ignores the hook's output.
  }
  return 0;
}

Future<void> _claudeHook(String event, Stream<List<int>> input, Map<String, String> env) async {
  final body = await _readAll(input, null);
  final base = env['AGENT_OFFICE_HOOK_URL'];
  final worker = env['AGENT_OFFICE_WORKER_ID'];
  if (base == null || base.isEmpty || worker == null || worker.isEmpty || body == null) return;
  final url = Uri.parse('$base/hooks/claude');
  final target = url.replace(queryParameters: {...url.queryParameters, 'worker': worker, 'event': event});
  for (var tries = hookTries; tries > 0; tries--) {
    try {
      await _post(target, env['AGENT_OFFICE_HOOK_TOKEN'] ?? '', body, const Duration(seconds: 3));
      return;
    } on SocketException catch (err) {
      // Only a refused connection is worth retrying: the office is restarting.
      if (!_refused(err) || tries <= 1) return;
      await Future<void>.delayed(const Duration(seconds: 1));
    } catch (_) {
      return;
    }
  }
}

bool _refused(SocketException err) {
  final code = err.osError?.errorCode;
  return code == 111 || code == 61 || code == 10061 || err.message.contains('Connection refused');
}

const _codexStdinMax = 64 * 1024;
const _codexMaxId = 160;
const _codexMaxText = 20000;

/// Only the bounded root-session fields leave the machine; message bodies and tool inputs don't.
Future<bool> _codexHook(String event, Stream<List<int>> input, Map<String, String> env) async {
  final raw = await _readAll(input, _codexStdinMax);
  if (raw == null || !codexHookEvents.contains(event)) return false;
  Object? payload;
  try {
    payload = jsonDecode(utf8.decode(raw, allowMalformed: true));
  } catch (_) {
    return false;
  }
  if (payload is! Map) return false;
  bool hasText(Object? v) => v is String && v.trim().isNotEmpty;
  String? allowed(Object? v, int max) => v is String && v.trim().isNotEmpty && v.trim().length <= max ? v.trim() : null;
  if (hasText(payload['agent_id']) || hasText(payload['agent_type'])) return false;
  final session = allowed(payload['session_id'], _codexMaxId);
  if (session == null) return false;
  final body = <String, Object>{'session_id': session, 'hook_event_name': event};
  final toolEvent = event == 'PreToolUse' || event == 'PostToolUse' || event == 'PermissionRequest';
  final source = event == 'SessionStart' ? allowed(payload['source'], _codexMaxId) : null;
  final prompt = event == 'UserPromptSubmit' ? allowed(payload['prompt'], _codexMaxText) : null;
  final tool = toolEvent ? allowed(payload['tool_name'], _codexMaxId) : null;
  final toolUseId = toolEvent ? allowed(payload['tool_use_id'], _codexMaxId) : null;
  final transcript = allowed(payload['transcript_path'], 4096);
  final turn = allowed(payload['turn_id'], _codexMaxId);
  if (source != null) body['source'] = source;
  if (prompt != null) body['prompt'] = prompt;
  if (tool != null) body['tool_name'] = tool;
  if (toolUseId != null) body['tool_use_id'] = toolUseId;
  if (turn != null) body['turn_id'] = turn;
  if (transcript != null) body['transcript_path'] = transcript;
  final base = env['AGENT_OFFICE_HOOK_URL'];
  final token = env['AGENT_OFFICE_HOOK_TOKEN'];
  final worker = env['AGENT_OFFICE_WORKER_ID'];
  if (base == null || base.isEmpty || token == null || token.isEmpty || worker == null || worker.isEmpty) {
    return false;
  }
  try {
    final url = Uri.parse(base).resolve('/hooks/codex').replace(queryParameters: {'worker': worker, 'event': event});
    final status = await _post(url, token, utf8.encode(jsonEncode(body)), const Duration(seconds: 2));
    return status >= 200 && status < 300;
  } catch (_) {
    return false;
  }
}

/// All of [input], or null past [max] bytes.
Future<List<int>?> _readAll(Stream<List<int>> input, int? max) async {
  final bytes = BytesBuilder(copy: false);
  var overflow = false;
  try {
    await for (final chunk in input) {
      if (overflow) continue;
      if (max != null && bytes.length + chunk.length > max) {
        overflow = true;
        continue;
      }
      bytes.add(chunk);
    }
  } catch (_) {
    return null;
  }
  return overflow ? null : bytes.takeBytes();
}

Future<int> _post(Uri url, String token, List<int> body, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await () async {
      final req = await client.postUrl(url);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
