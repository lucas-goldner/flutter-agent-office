// Claude Code: hooks from a settings file the office writes (its own hook route, /hooks/claude),
// usage read off the session transcript and booked in the budget, and tasks the office names.
// Ported from upstream's src/server/providers/claude.ts.

import 'dart:convert';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import '../hook.dart';
import '../lifecycle.dart';
import '../stations.dart';
import 'provider.dart';

/// The Claude Code hooks the office listens to.
const claudeHookEvents = [
  'SessionStart',
  'UserPromptSubmit',
  'Stop',
  'Notification',
  'PermissionRequest',
  'PreToolUse',
  'PostToolUse',
  'PostToolUseFailure',
];

/// First-run screens Claude shows before it can take a prompt.
final _setupPrompt = RegExp(
  r'trust this folder|Do you trust the files|Select login method|Choose the text style|Press Enter to continue|Bypass Permissions mode',
  caseSensitive: false,
);
final _notLoggedIn = RegExp(r'Not logged in\s*·\s*Run /login|Invalid API key|Please run /login', caseSensitive: false);

/// What Claude is set up with on a floor.
class ClaudeSetup {
  const ClaudeSetup({required this.settings});

  /// Its --settings: the office's hooks.
  final String settings;
}

/// Claude Code's --settings for every worker: each hook event posted to the office (see hook.dart).
String writeClaudeHookSettings(String dataDir, List<String> office) {
  final settingsPath = p.join(dataDir, 'claude-hooks.json');
  final hooks = <String, Object>{
    for (final event in claudeHookEvents)
      event: [
        {
          'hooks': [
            {'type': 'command', 'command': claudeHookCommand(event, office: office)},
          ],
        },
      ],
  };
  writePrivate(settingsPath, const JsonEncoder.withIndent('  ').convert({'hooks': hooks}));
  return settingsPath;
}

String describeTool(Map payload) {
  final name = payload['tool_name'] ?? 'tool';
  final input = payload['tool_input'];
  Object? field(String k) => input is Map ? input[k] : null;
  final detail =
      field('command') ?? field('file_path') ?? field('pattern') ?? field('url') ?? field('description') ?? '';
  final hasDetail = detail is String ? detail.isNotEmpty : detail != false && detail != 0;
  return truncateLine(hasDetail ? '$name: $detail' : '$name', 80);
}

/// A tool call finished. Tests or a build that failed again (by exit code, or by the summary it
/// printed when the exit code was piped away) and the worker puts its head in its hands, until its
/// next tool call; a passing run ends the streak.
void _noteOutcome(WorkerHandle h, Map payload, bool failed) {
  if (payload['is_interrupt'] == true || toolAction(payload['tool_name'], payload['tool_input']) != WorkerAction.test) {
    return;
  }
  final res = payload['tool_response'];
  final output = [
    payload['error'],
    if (res is Map) res['stdout'],
    if (res is Map) res['stderr'],
  ].whereType<String>().join('\n');
  if (!failed && !outputFailed(output)) {
    h.failStreak = 0;
    return;
  }
  if (++h.failStreak < failsToDespair || h.info.action == WorkerAction.failing) return;
  h.info.action = WorkerAction.failing;
  h.emit();
}

/// Claude Code hook callback. Any session id or transcript it names is the worker's now, and a
/// malformed payload still counts as the event. The trust and login screens are also read off its
/// screen (see [claudeBlocked]), so only a prompt or its session starting clears bootBlocked here.
bool claudeHook(WorkerHandle h, String event, Object? payload) {
  final info = h.info;
  final m = payload is Map ? payload : const {};
  final now = DateTime.now().millisecondsSinceEpoch;
  final sessionId = m['session_id'];
  if (sessionId is String && sessionId.isNotEmpty && sessionId != info.sessionId) {
    info.sessionId = sessionId;
    h.persist();
  }
  final transcript = m['transcript_path'];
  if (transcript is String && transcript != h.tracker.transcript) {
    h.tracker.transcript = transcript;
    h.persist();
  }
  h.scheduleScan();
  switch (event) {
    case 'SessionStart':
      if (m['source'] == 'clear') {
        h.clearTask();
        h.failStreak = 0;
      }
      if (info.status == WorkerStatus.starting || (h.bootBlocked && info.status == WorkerStatus.needsInput)) {
        h.bootBlocked = false;
        h.setStatus(WorkerStatus.idle);
      }
    case 'UserPromptSubmit':
      h.bootBlocked = false;
      info.action = null;
      final prompt = m['prompt'];
      if (prompt is String) {
        info.activity = truncateLine(prompt, 80);
        h.notePrompt(prompt);
      }
      if (info.status != WorkerStatus.working) {
        h.setStatus(WorkerStatus.working);
      } else {
        h.emit();
      }
    case 'PreToolUse':
      if (m['tool_name'] == 'AskUserQuestion') {
        h.setStatus(WorkerStatus.needsInput);
      } else {
        final activity = describeTool(m);
        info.activity = activity;
        info.action = toolAction(m['tool_name'], m['tool_input']);
        h.noteTool(activity);
        if (info.status != WorkerStatus.working) {
          h.setStatus(WorkerStatus.working);
        } else {
          h.emit();
        }
      }
    case 'PostToolUse':
    case 'PostToolUseFailure':
      _noteOutcome(h, m, event == 'PostToolUseFailure');
      answered(h, now);
    case 'PermissionRequest':
      wantsPermission(h, describeTool(m));
    case 'Notification':
      notified(h, m['notification_type'], now);
    case 'Stop':
      h.setStatus(WorkerStatus.done);
  }
  return true;
}

/// Claude can sit at its prompt without being usable: stuck on a first-run screen, or not signed in
/// on this machine. That needs a human, until the screen moves on.
String? claudeBlocked(String text, bool early) {
  if (_notLoggedIn.hasMatch(text)) return "Claude isn't signed in on this machine — open the terminal and type /login";
  if (_setupPrompt.hasMatch(text) && early) return 'Waiting on a setup prompt (trust / login) — open the terminal';
  return null;
}

class ClaudeAdapter extends ProviderAdapter {
  const ClaudeAdapter();

  @override
  AgentProvider get id => AgentProvider.claude;

  @override
  List<String> get scrubEnv => const [
    'CLAUDECODE',
    'CLAUDE_CODE_ENTRYPOINT',
    'CLAUDE_CODE_SSE_PORT',
    'CLAUDE_CODE_EXECPATH',
    'CLAUDE_PID',
    'CLAUDE_EFFORT',
  ];

  @override
  List<String> get scrubPrefixes => const ['CLAUDE_CODE_SESSION', 'CLAUDE_CODE_CHILD', 'CLAUDE_CODE_MESSAGING'];

  @override
  Object? prepare(ProviderFloor floor) => ClaudeSetup(settings: writeClaudeHookSettings(floor.dataDir, floor.office));

  @override
  LaunchPlan launch(LaunchInput input) {
    final info = input.h.info;
    final setup = input.setup as ClaudeSetup;
    final args = input.args..insertAll(0, ['--settings', setup.settings]);
    // A model/effort chosen for this worker overrides whatever --agent-args set office-wide.
    if (info.model != null) args.addAll(['--model', info.model!]);
    if (info.effort != null) args.addAll(['--effort', info.effort!.wire]);
    // The queue agent only ever adds to the queue: without these it can't touch the checkout's files.
    if (input.station == StationKind.queue) args.addAll(['--disallowedTools', ...queueAgentDisallowedTools]);
    if (input.resumeSessionId != null) args.addAll(['--resume', input.resumeSessionId!]);
    // `--` so a prompt like "- fix login" is never parsed as a CLI option.
    final prompt = input.prompt;
    if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt]);
    return LaunchPlan(args: args);
  }

  @override
  String? get signIn => 'claude';

  // SessionStart fires as soon as Claude can take input: still silent, it's blocked on a human.
  @override
  String? get bootHint => 'Waiting on a setup prompt (trust / login) — open the terminal';

  @override
  RegExp? get titleNoise => RegExp(r'^claude( code)?$', caseSensitive: false);

  // Resuming a conversation Claude no longer has ("No conversation found") exits before Claude ever starts.
  @override
  bool get freshIfResumeFails => true;

  @override
  ProviderHook? get hook => const ProviderHook(strictJson: false, handle: claudeHook);

  // OSC 9;4 progress (Claude Code emits it): 0 = idle, anything else = busy. Catches Esc-cancel,
  // which fires no Stop hook.
  @override
  bool get screenProgress => true;

  @override
  ScreenBlocked? get screenBlocked => claudeBlocked;

  @override
  AdapterUsage? get usage => const AdapterUsage(transcript: true);

  @override
  bool get namesTasks => true;
}
