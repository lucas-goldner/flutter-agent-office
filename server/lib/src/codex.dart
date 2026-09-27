import 'dart:convert';

import 'hook.dart';

const codexHookEvents = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'PermissionRequest',
  'Stop',
  'Interrupt',
];

/// The bounded event shape forwarded to the worker bridge.
class CodexHookEvent {
  CodexHookEvent({
    required this.sessionId,
    required this.event,
    this.source,
    this.prompt,
    this.tool,
    this.toolUseId,
    this.turnId,
    this.transcriptPath,
  });

  final String sessionId;

  /// One of [codexHookEvents].
  final String event;
  String? source;
  String? prompt;
  String? tool;
  String? toolUseId;
  String? turnId;

  /// Only the server-side metric reader uses this path; never sent to browsers.
  String? transcriptPath;

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'event': event,
    'source': ?source,
    'prompt': ?prompt,
    'tool': ?tool,
    'toolUseId': ?toolUseId,
    'turnId': ?turnId,
    'transcriptPath': ?transcriptPath,
  };
}

const _maxId = 160;
const _maxText = 20000;

String? _bounded(Object? value, int max) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isNotEmpty && text.length <= max ? text : null;
}

bool _hasText(Object? value) => value is String && value.trim().isNotEmpty;

/// Validate and compact a native Codex hook payload. Transcript paths are passed only to the
/// server-side metric reader; message bodies and other unknown fields are discarded. Events
/// carrying an agent id/type are subagent-scoped and are ignored; Codex reports those hooks with
/// the root session id, so adopting them would corrupt root state.
CodexHookEvent? normalizeCodexHook(String event, Object? payload) {
  if (!codexHookEvents.contains(event) || payload is! Map) return null;
  if (_hasText(payload['agent_id']) || _hasText(payload['agent_type'])) return null;

  final sessionId = _bounded(payload['session_id'], _maxId);
  if (sessionId == null) return null;
  final result = CodexHookEvent(sessionId: sessionId, event: event);

  result.transcriptPath = _bounded(payload['transcript_path'], 4096);
  result.turnId = _bounded(payload['turn_id'], _maxId);
  if (event == 'SessionStart') {
    result.source = _bounded(payload['source'], _maxId);
  } else if (event == 'UserPromptSubmit') {
    result.prompt = _bounded(payload['prompt'], _maxText);
  } else if (event == 'PreToolUse' || event == 'PostToolUse' || event == 'PermissionRequest') {
    result.tool = _bounded(payload['tool_name'], _maxId);
    result.toolUseId = _bounded(payload['tool_use_id'], _maxId);
  }
  return result;
}

/// Alias for callers that only need a validity check.
bool validateCodexHook(String event, Object? payload) => normalizeCodexHook(event, payload) != null;

/// Build the CLI config overrides for all lifecycle hooks: each runs `<office> hook codex <event>`
/// (see hook.dart). The command is encoded as a TOML basic string so paths containing spaces remain
/// valid; the command itself is shell-quoted. [office] defaults to [officeCommand].
List<String> codexHookArgs([List<String>? office]) {
  final exe = office ?? officeCommand();
  final args = <String>[];
  for (final event in codexHookEvents) {
    final command = [...exe, 'hook', 'codex', event].map(shellQuote).join(' ');
    final config = 'hooks.$event=[{hooks=[{type="command",command=${jsonEncode(command)},timeout=3}]}]';
    args.addAll(['-c', config]);
  }
  return args;
}
