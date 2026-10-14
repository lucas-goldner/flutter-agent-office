// Cursor CLI (cursor-agent): its hooks, the helper they run, and its command line. Ported from
// upstream's src/server/cursor.ts; the helper is the office's own executable,
// `agent-office hook cursor <event> <worker>` (see hook.dart), where upstream wrote a Node one.
//
// The CLI reads hooks from ~/.cursor/hooks.json, which is the person's own and the office never
// touches, and from <folder>/.cursor/hooks.json. Nothing moves either (CURSOR_CONFIG_DIR only moves
// its settings and chats), and its terminal only fires the prompt and stop hooks when one of those
// two files has them, so a plugin's hooks (--plugin-dir) aren't enough. So each worker's own entries
// go into the hooks.json of the folder it works in as it starts, and come out again when it ends.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart' show excludeFromGit;
import 'hook.dart' show shellQuote;
import 'lifecycle.dart';

/// Cursor's hook events the office listens to, and the lifecycle event each one is (see lifecycle.dart).
const cursorHookEvents = {
  'sessionStart': 'SessionStart',
  'beforeSubmitPrompt': 'UserPromptSubmit',
  'preToolUse': 'PreToolUse',
  'postToolUse': 'PostToolUse',
  'postToolUseFailure': 'PostToolUseFailure',
  'stop': 'Stop',
};

const _maxId = 160;
const _maxText = 20000;

/// A chat id goes back on the command line (`--resume=<id>`), so it's never taken as anything but an id.
final _chatId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');

/// What marks a payload as a subagent's or a cloud agent's rather than the desk's own session.
const cursorChildFields = ['subagent_id', 'subagent_type', 'parent_conversation_id', 'agent_id', 'agent_type'];

/// What every hook command the office writes has in it: how its entries are told from the project's own.
const _hookMark = "'hook' 'cursor' ";
const _hookTimeoutS = 5;

/// Validate and compact a Cursor hook payload. A subagent's events are ignored so they cannot
/// overwrite the desk's root status. Tool inputs and outputs, the assistant's messages and the
/// transcript path are discarded.
LifecycleReport? normalizeCursorHook(String event, Object? payload) {
  final name = cursorHookEvents[event];
  if (name == null || payload is! Map) return null;
  if (cursorChildFields.any((k) => hasText(payload[k])) || payload['is_background_agent'] == true) return null;
  final sessionId = payload.containsKey('conversation_id') ? payload['conversation_id'] : payload['session_id'];
  if (sessionId is! String || !_chatId.hasMatch(sessionId)) return null;
  final tools = event == 'preToolUse' || event == 'postToolUse' || event == 'postToolUseFailure';
  return LifecycleReport(
    sessionId: sessionId,
    event: name,
    prompt: event == 'beforeSubmitPrompt' ? boundedText(payload['prompt'], _maxText) : null,
    tool: tools ? boundedText(payload['tool_name'], _maxId) : null,
    toolUseId: tools ? boundedText(payload['tool_use_id'], _maxId) : null,
  );
}

/// What the helper posts for one of [workerId]'s hook events, or null when it says nothing (another
/// worker's session, a subagent's, a malformed payload).
Map<String, Object>? cursorHookBody(String event, Object? input, Map<String, String> env, String workerId) {
  // Every Cursor session in this folder runs this: only the worker it was written for reports.
  if (!cursorHookEvents.containsKey(event) || env['AGENT_OFFICE_WORKER_ID'] != workerId || input is! Map) return null;
  if (cursorChildFields.any((k) => hasText(input[k])) || input['is_background_agent'] == true) return null;
  final session = boundedText(
    input.containsKey('conversation_id') ? input['conversation_id'] : input['session_id'],
    _maxId,
  );
  if (session == null) return null;
  final body = <String, Object>{'conversation_id': session, 'hook_event_name': event};
  final prompt = input['prompt'];
  if (event == 'beforeSubmitPrompt' && prompt is String && prompt.trim().isNotEmpty) {
    final text = prompt.trim();
    body['prompt'] = text.length > _maxText ? text.substring(0, _maxText) : text;
  }
  if (event == 'preToolUse' || event == 'postToolUse' || event == 'postToolUseFailure') {
    final tool = boundedText(input['tool_name'], _maxId);
    final toolUseId = boundedText(input['tool_use_id'], _maxId);
    if (tool != null) body['tool_name'] = tool;
    if (toolUseId != null) body['tool_use_id'] = toolUseId;
  }
  return body;
}

/// The folder's hooks.json as it is: null when there isn't one, and [_unreadable] for one the office
/// can't read (it's left alone).
({Map<String, dynamic> config, String text})? _readHooks(String file) {
  final f = File(file);
  if (!f.existsSync()) return null;
  try {
    final text = f.readAsStringSync();
    final config = jsonDecode(text);
    if (config is Map<String, dynamic> && config['hooks'] is Map<String, dynamic>) return (config: config, text: text);
  } catch (_) {
    // unreadable
  }
  return _unreadable;
}

const ({Map<String, dynamic> config, String text}) _unreadable = (config: {}, text: '');

/// Whether a hook entry is the office's, and [workerId]'s when one is named.
bool _isOffice(Object? entry, [String? workerId]) {
  final command = entry is Map ? entry['command'] : null;
  return command is String &&
      command.contains(_hookMark) &&
      (workerId == null || command.endsWith(' ${shellQuote(workerId)}'));
}

/// Takes [workerId]'s entries out of [config].
void _strip(Map<String, dynamic> config, String workerId) {
  final hooks = config['hooks'] as Map<String, dynamic>;
  for (final event in List.of(hooks.keys)) {
    final entries = hooks[event];
    if (entries is! List || !entries.any((e) => _isOffice(e, workerId))) continue;
    final kept = [
      for (final e in entries)
        if (!_isOffice(e, workerId)) e,
    ];
    if (kept.isNotEmpty) {
      hooks[event] = kept;
    } else {
      hooks.remove(event);
    }
  }
}

/// A project's own hooks.json as it was before the office's first entry went in, to put back exactly.
final _originals = <String, String>{};

bool _sameJson(String text, Object config) {
  try {
    return jsonEncode(jsonDecode(text)) == jsonEncode(config);
  } catch (_) {
    return false;
  }
}

/// [config] as text, laid out the way [like] was.
String _format(Object config, [String? like]) {
  final indent = (like != null ? RegExp(r'^([ \t]+)\S', multiLine: true).firstMatch(like)?.group(1) : null) ?? '  ';
  return JsonEncoder.withIndent(indent).convert(config) + (like != null && !like.endsWith('\n') ? '' : '\n');
}

String cursorHooksPath(String cwd) => p.join(cwd, '.cursor', 'hooks.json');

/// Puts a worker's hook entries in the hooks.json of the folder it works in, next to whatever the
/// project has there. Each entry names its worker, and the helper only speaks for that one, so
/// workers sharing a folder (the board agents, in the project itself) don't report for each other.
/// Says whether they're in: a hooks.json the office can't read is left as it is. [office] is how the
/// hooks run the office's own executable.
bool addCursorHooks(String cwd, List<String> office, String workerId) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(workerId)) return false;
  final file = cursorHooksPath(cwd);
  final found = _readHooks(file);
  if (identical(found, _unreadable)) return false;
  final config = found?.config ?? <String, dynamic>{'version': 1, 'hooks': <String, dynamic>{}};
  final before = found?.text;
  // The project's own file, untouched until now: kept to put back as it was (see removeCursorHooks).
  if (before != null && !before.contains(_hookMark)) _originals[file] = before;
  // Left behind by a run that was cut off.
  _strip(config, workerId);
  final hooks = config['hooks'] as Map<String, dynamic>;
  for (final event in cursorHookEvents.keys) {
    final entries = hooks[event] is List ? hooks[event] as List : const [];
    final command = [...office, 'hook', 'cursor', event, workerId].map(shellQuote).join(' ');
    hooks[event] = [
      ...entries,
      {'command': command, 'timeout': _hookTimeoutS},
    ];
  }
  try {
    Directory(p.dirname(file)).createSync(recursive: true);
    File(file).writeAsStringSync(_format(config, before));
  } catch (_) {
    return false;
  }
  // A file the office made is no change of the worker's: git doesn't list it.
  if (before == null) excludeFromGit(cwd, '.cursor/hooks.json');
  return true;
}

/// Takes a worker's hook entries out again, and the file with them when nothing else is in it.
void removeCursorHooks(String cwd, String workerId) {
  final file = cursorHooksPath(cwd);
  final found = _readHooks(file);
  if (found == null || identical(found, _unreadable) || !found.text.contains(_hookMark)) return;
  final config = found.config;
  _strip(config, workerId);
  final hooks = config['hooks'] as Map<String, dynamic>;
  final shared = hooks.values.any((entries) => entries is List && entries.any((e) => _isOffice(e)));
  final original = shared ? null : _originals[file];
  if (!shared) _originals.remove(file);
  try {
    if (original != null && _sameJson(original, config)) {
      File(file).writeAsStringSync(original);
    } else if (hooks.isEmpty && config.keys.every((k) => k == 'version' || k == 'hooks')) {
      File(file).deleteSync();
      try {
        Directory(p.dirname(file)).deleteSync(); // only when the office's file was all it held
      } catch (_) {
        // the project has other things in .cursor
      }
    } else {
      File(file).writeAsStringSync(_format(config, found.text));
    }
  } catch (_) {
    // The folder is gone (a worktree that was deleted), or can't be written: nothing to take out.
  }
}

/// Drop launch flags the office sets itself, the ones that would take a worker out of its terminal
/// or its folder, and the ones that skip Cursor's permission prompts (the office never passes those).
List<String> withoutCursorLaunchArgs(List<String> args) {
  const skipValue = {'--model', '--workspace', '--worktree-base', '--output-format', '--new-session-id'};
  // These take a value only when one follows.
  const skipOptional = {'--resume', '--worktree', '-w'};
  const skipFlag = {
    '--force', '-f', '--yolo', '--trust', '--continue', '--print', '-p', '--list-models', //
    '--stream-partial-output', '--skip-worktree-setup',
  };
  final withValue = [
    for (final f in [...skipValue, ...skipOptional])
      if (f.startsWith('--')) '$f=',
  ];
  final clean = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--') break;
    if (skipFlag.contains(arg)) continue;
    if (skipValue.contains(arg) || skipOptional.contains(arg)) {
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) i++;
      continue;
    }
    if (withValue.any(arg.startsWith)) continue;
    clean.add(arg);
  }
  return clean;
}

/// What a Cursor worker's desk says when its screen shows it can't be used yet.
String? cursorBlocked(String text, [bool early = false]) =>
    RegExp(r'Press any key to log in', caseSensitive: false).hasMatch(text)
    ? "Cursor isn't signed in on this machine — open the terminal and log in"
    : null;
