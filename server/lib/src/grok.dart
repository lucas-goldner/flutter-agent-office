// Grok's hooks: which events the office listens to, the bounded shape they're compacted to, and the
// isolated GROK_HOME that carries only the office's hooks (so a worker never edits ~/.grok/hooks).
// Each hook runs the office's own executable, `agent-office hook grok <event>` (see hook.dart), where
// upstream wrote a Node helper. Ported from upstream's src/server/grok.ts.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'hook.dart' show shellQuote;
import 'lifecycle.dart';
import 'providers/provider.dart' show writePrivate;

const grokHookEvents = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'Notification',
  'Stop',
  'StopFailure',
  'StopCancelled',
];

const _maxId = 160;
const _maxText = 20000;

/// Validate and compact a Grok hook payload. Child-session events (a subagent's own turn) are
/// ignored so they cannot overwrite the desk's root status. Message bodies and tool inputs are
/// discarded.
LifecycleReport? normalizeGrokHook(String event, Object? payload) {
  if (!grokHookEvents.contains(event) || payload is! Map) return null;
  if (hasText(pickField(payload, const ['subagentType', 'subagent_type', 'agent_id', 'agent_type']))) return null;
  final sessionId = boundedText(pickField(payload, const ['sessionId', 'session_id']), _maxId);
  if (sessionId == null) return null;
  final tools = event == 'PreToolUse' || event == 'PostToolUse';
  final stop = event == 'Stop' || event == 'StopFailure' || event == 'StopCancelled';
  return LifecycleReport(
    sessionId: sessionId,
    event: event,
    source: event == 'SessionStart' ? boundedText(payload['source'], _maxId) : null,
    prompt: event == 'UserPromptSubmit' ? boundedText(payload['prompt'], _maxText) : null,
    tool: tools ? boundedText(pickField(payload, const ['toolName', 'tool_name']), _maxId) : null,
    toolUseId: tools ? boundedText(pickField(payload, const ['toolUseId', 'tool_use_id']), _maxId) : null,
    notificationType: event == 'Notification'
        ? boundedText(pickField(payload, const ['notificationType', 'notification_type']), _maxId)
        : null,
    reason: stop ? boundedText(payload['reason'], _maxId) : null,
  );
}

bool validateGrokHook(String event, Object? payload) => normalizeGrokHook(event, payload) != null;

/// Where Grok runs for the office: its home and its leader socket.
typedef GrokHome = ({String home, String socket});

/// An isolated GROK_HOME that carries only the office's hooks, so a worker never writes into the
/// user's ~/.grok/hooks. Auth still comes from GROK_AUTH_PATH when the office sets it. Each hook runs
/// [office] (the office's own executable).
GrokHome writeGrokHome(String dataDir, List<String> office) {
  final home = p.join(dataDir, 'grok-home');
  final hooksDir = p.join(home, 'hooks');
  Directory(hooksDir).createSync(recursive: true);
  final hooks = <String, Object>{
    for (final event in grokHookEvents)
      event: [
        {
          'hooks': [
            {
              'type': 'command',
              'command': [...office, 'hook', 'grok', event].map(shellQuote).join(' '),
              'timeout': 3,
            },
          ],
        },
      ],
  };
  writePrivate(p.join(hooksDir, 'agent-office.json'), const JsonEncoder.withIndent('  ').convert({'hooks': hooks}));
  return (home: home, socket: p.join(dataDir, 'grok-leader.sock'));
}

/// Drop launch flags the office always sets itself, plus model/effort/session flags it may replace.
List<String> withoutGrokLaunchArgs(List<String> args) {
  const skipValue = {
    '--model', '-m', '--effort', '--reasoning-effort', '--session-id', '-s', '--resume', '-r', '--leader-socket', //
  };
  const skipFlag = {'--no-alt-screen', '--trust', '--continue', '-c', '--fullscreen', '--minimal'};
  const prefixes = [
    '--model=', '--effort=', '--reasoning-effort=', '--session-id=', '--resume=', '--leader-socket=', //
  ];
  final clean = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (skipFlag.contains(arg)) continue;
    if (skipValue.contains(arg)) {
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) i++;
      continue;
    }
    if (prefixes.any(arg.startsWith) || (arg.startsWith('-m') && arg.length > 2 && arg != '-minimal')) continue;
    clean.add(arg);
  }
  return clean;
}
