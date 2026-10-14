// Muse Code's hooks: which events the office listens to, the bounded shape they're compacted to, and
// the isolated XDG tree that carries only the office's Muse settings and hooks (so a worker never
// edits ~/.config/muse). Each hook runs the office's own executable, `agent-office hook muse <event>`
// (see hook.dart), where upstream wrote a Node helper. Ported from upstream's src/server/muse.ts.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'hook.dart' show shellQuote;
import 'lifecycle.dart';
import 'providers/provider.dart' show writePrivate;

const museHookEvents = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'PostToolUseFailure',
  'Notification',
  'PermissionRequest',
  'Stop',
  'StopFailure',
];

const _maxId = 160;
const _maxText = 20000;

/// Validate and compact a Muse hook payload. Child-session events are ignored so they cannot
/// overwrite the desk's root status. Transcript paths and assistant message bodies are discarded.
/// An [event] Muse didn't name on the command line is taken from the payload's own hook_event_name.
LifecycleReport? normalizeMuseHook(String event, Object? payload) {
  if (payload is! Map) return null;
  final name = museHookEvents.contains(event)
      ? event
      : boundedText(pickField(payload, const ['hook_event_name', 'hookEventName']), _maxId);
  if (name == null || !museHookEvents.contains(name)) return null;
  const child = ['subagentType', 'subagent_type', 'agent_id', 'agent_type', 'parent_session_id', 'parent_session'];
  if (hasText(pickField(payload, child))) return null;
  final sessionId = boundedText(pickField(payload, const ['sessionId', 'session_id']), _maxId);
  if (sessionId == null) return null;
  final tools =
      name == 'PreToolUse' || name == 'PostToolUse' || name == 'PostToolUseFailure' || name == 'PermissionRequest';
  return LifecycleReport(
    sessionId: sessionId,
    event: name,
    source: name == 'SessionStart' ? boundedText(payload['source'], _maxId) : null,
    prompt: name == 'UserPromptSubmit' ? boundedText(payload['prompt'], _maxText) : null,
    tool: tools ? boundedText(pickField(payload, const ['toolName', 'tool_name', 'tool']), _maxId) : null,
    toolUseId: tools ? boundedText(pickField(payload, const ['toolUseId', 'tool_use_id']), _maxId) : null,
    notificationType: name == 'Notification'
        ? boundedText(pickField(payload, const ['notificationType', 'notification_type']), _maxId)
        : null,
    reason: name == 'Stop' || name == 'StopFailure' ? boundedText(payload['reason'], _maxId) : null,
  );
}

bool validateMuseHook(String event, Object? payload) => normalizeMuseHook(event, payload) != null;

String? _safeMuseId(Object? value) {
  if (value is! String || value.isEmpty || value.length > 128) return null;
  if (RegExp(r'[\s\p{Cc}\p{Cf}]', unicode: true).hasMatch(value)) return null;
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value) ? value : null;
}

({String? provider, String? model}) _userMuseDefaults(String? userMuseDir) {
  if (userMuseDir == null) return (provider: null, model: null);
  try {
    final raw = jsonDecode(File(p.join(userMuseDir, 'settings.json')).readAsStringSync());
    if (raw is! Map) return (provider: null, model: null);
    final provider = raw['provider'];
    return (
      provider: provider == 'meta' || provider == 'echo' || provider == 'local' ? provider as String : null,
      model: _safeMuseId(raw['model']),
    );
  } catch (_) {
    return (provider: null, model: null);
  }
}

void _linkAuth(String src, String dest) {
  if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) return;
  try {
    Link(dest).createSync(src);
  } catch (_) {
    try {
      File(src).copySync(dest);
    } catch (_) {
      // Login still happens in the TUI when auth is missing.
    }
  }
}

/// The office's own XDG tree for Muse.
class MuseHome {
  const MuseHome({required this.home, required this.configHome, required this.dataHome, required this.stateHome});

  final String home;
  final String configHome;
  final String dataHome;
  final String stateHome;
}

/// An isolated XDG tree that carries only the office's Muse settings and hooks, so a worker never
/// writes into the user's ~/.config/muse. Auth is linked from the user's muse dir when present. Each
/// hook runs [office] (the office's own executable).
MuseHome writeMuseHome(String dataDir, List<String> office, [String? userMuseDir]) {
  final home = p.join(dataDir, 'muse-home');
  final configHome = p.join(home, 'config');
  final dataHome = p.join(home, 'share');
  final stateHome = p.join(home, 'state');
  final configDir = p.join(configHome, 'muse');
  for (final dir in [configDir, dataHome, stateHome]) {
    Directory(dir).createSync(recursive: true);
  }
  final hooks = <String, Object>{
    for (final event in museHookEvents)
      event: [
        {
          'hooks': [
            {
              'type': 'command',
              'command': [...office, 'hook', 'muse', event].map(shellQuote).join(' '),
              'timeout': 3,
            },
          ],
        },
      ],
  };
  final defaults = _userMuseDefaults(userMuseDir);
  final settings = {
    'schema_version': 1,
    'provider': defaults.provider ?? 'meta',
    'model': ?defaults.model,
    'hooks': hooks,
  };
  writePrivate(p.join(configDir, 'settings.json'), const JsonEncoder.withIndent('  ').convert(settings));
  if (userMuseDir != null) {
    final auth = p.join(userMuseDir, 'auth.json');
    if (File(auth).existsSync()) _linkAuth(auth, p.join(configDir, 'auth.json'));
  }
  return MuseHome(home: home, configHome: configHome, dataHome: dataHome, stateHome: stateHome);
}

/// Drop launch flags the office always sets itself, plus model/effort/session flags it may replace.
List<String> withoutMuseLaunchArgs(List<String> args) {
  const skipValue = {
    '--model', '--reasoning-effort', '--provider', '--workspace', '--worktree', '--worktree-base', //
    '--worktree-existing', '--approval-mode', '--permission-profile', '--sandbox-network',
  };
  const skipFlag = {
    '--trust-workspace', '--yolo', '--disable-approval', '--disable-sandbox', '--disable-write', //
    '--disable-shell', '--last', '-w',
  };
  const skipCommand = {'resume', 'exec', 'serve'};
  const prefixes = [
    '--model=',
    '--reasoning-effort=',
    '--provider=',
    '--workspace=',
    '--worktree=',
    '--approval-mode=',
  ];
  final clean = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--') break;
    if (skipFlag.contains(arg) || skipCommand.contains(arg)) {
      if (skipCommand.contains(arg) && i + 1 < args.length && !args[i + 1].startsWith('-')) i++;
      continue;
    }
    if (skipValue.contains(arg)) {
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) i++;
      continue;
    }
    if (prefixes.any(arg.startsWith)) continue;
    clean.add(arg);
  }
  return clean;
}
