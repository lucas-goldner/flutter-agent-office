// Codex: its native lifecycle hooks (see ../codex.dart), set on its command line, report on
// /hooks/codex; its usage is read from the root session's rollout (see codex_usage.dart).
// Ported from upstream's src/server/providers/codex.ts.

import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import '../codex.dart';
import '../codex_usage.dart';
import '../lifecycle.dart';
import 'provider.dart';

class CodexState {
  CodexUsageReader usage = CodexUsageReader();

  /// Where its sessions are logged (see [codexHome]).
  String? home;

  /// Its root session's rollout, as its hooks name it.
  String? transcript;

  /// Its tool calls in flight, and which of them wait on the person (see [_CodexTools]).
  final tools = <String, String>{};
  final pending = <String>{};
  bool permissionUnknown = false;
}

class CodexSetup {
  const CodexSetup({required this.office});

  /// How its hooks run the office's own executable.
  final List<String> office;
}

/// Where a Codex worker's sessions are logged, for reading its usage.
String codexHome(String cwd, Map<String, String> env) {
  final configured = env['CODEX_HOME'];
  final home = configured != null && configured.isNotEmpty
      ? configured
      : p.join(env['HOME'] ?? Platform.environment['HOME'] ?? '', '.codex');
  return p.normalize(p.join(p.absolute(cwd), home));
}

/// Codex's hooks never say a question was answered, so its tool calls are followed one by one: one
/// that asks the person something, or wants permission, keeps it needing input until it's over.
class _CodexTools implements ToolTracker {
  _CodexTools(this.s);

  final CodexState s;

  @override
  void clear() {
    s.tools.clear();
    s.pending.clear();
    s.permissionUnknown = false;
  }

  @override
  void started(String? tool, String? toolUseId) {
    if (toolUseId != null && s.tools.length < 256) s.tools[toolUseId] = tool ?? '';
    if (RegExp(r'(?:^|[.])(?:AskUserQuestion|request_user_input)$').hasMatch(tool ?? '')) {
      if (toolUseId != null) {
        s.pending.add(toolUseId);
      } else {
        s.permissionUnknown = true;
      }
    }
  }

  @override
  void permission(String? tool) {
    // PermissionRequest has no tool_use_id in the native schema. Keep every matching
    // active call pending so an unrelated parallel tool cannot dismiss the prompt.
    final candidates = [
      for (final e in s.tools.entries)
        if (e.value == tool) e.key,
    ];
    if (candidates.isEmpty) s.permissionUnknown = true;
    s.pending.addAll(candidates);
  }

  @override
  void finished(String? toolUseId) {
    if (toolUseId != null) {
      s.tools.remove(toolUseId);
      s.pending.remove(toolUseId);
    }
  }

  @override
  bool waiting() => s.pending.isNotEmpty || s.permissionUnknown;
}

/// Native Codex lifecycle hooks register the root rollout for bounded metric reads.
bool _codexHook(WorkerHandle h, String event, Object? payload) {
  final report = normalizeCodexHook(event, payload);
  if (report == null) return false;
  final s = h.state as CodexState;
  return reduceLifecycle(
    h,
    LifecycleReport(
      sessionId: report.sessionId,
      event: report.event,
      source: report.source,
      prompt: report.prompt,
      tool: report.tool,
      toolUseId: report.toolUseId,
    ),
    onSessionSwitch: () {
      h.info.usage = null;
      s.transcript = null;
      s.usage = CodexUsageReader();
    },
    onReport: () {
      if (report.transcriptPath != null) s.transcript = report.transcriptPath;
      h.scheduleScan();
    },
    tools: _CodexTools(s),
  );
}

void _scan(WorkerHandle h) {
  final info = h.info;
  final s = h.state as CodexState;
  final transcript = s.transcript, home = s.home, session = info.sessionId;
  if (transcript == null || home == null || session == null) return;
  final usage = s.usage.read(transcript, session, home);
  if (usage != null && jsonEncode(usage.toJson()) != jsonEncode(info.usage?.toJson())) {
    info.usage = usage;
    h.emit();
    h.persist();
  }
}

class CodexAdapter extends ProviderAdapter {
  const CodexAdapter();

  @override
  AgentProvider get id => AgentProvider.codex;

  @override
  List<String> get scrubEnv => const ['CODEX_THREAD_ID', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE'];

  @override
  Object? createState() => CodexState();

  @override
  Object? prepare(ProviderFloor floor) => CodexSetup(office: floor.office);

  @override
  LaunchPlan launch(LaunchInput input) {
    final setup = input.setup as CodexSetup;
    // Resumed too: Codex resumes on whatever its config says now, not on the model the session ran on.
    final args = codexModelArgs(input.args, input.h.info.model, input.h.info.effort)
      ..addAll([...codexHookArgs(setup.office), '--no-alt-screen']);
    if (input.resumeSessionId != null) args.addAll(['resume', input.resumeSessionId!]);
    final prompt = input.prompt;
    if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt]);
    _CodexTools(input.h.state as CodexState).clear();
    return LaunchPlan(args: args, rotateToken: true);
  }

  @override
  String? get bootHint => 'Open the terminal: complete login and review Office hooks in /hooks';

  @override
  ProviderHook? get hook => const ProviderHook(strictJson: true, handle: _codexHook);

  @override
  AdapterUsage? get usage => AdapterUsage(
    persisted: true,
    scanOnExit: true,
    scan: _scan,
    locate: (h, cwd, env) => (h.state as CodexState).home = codexHome(cwd, env),
    save: (s) => {'codexTranscript': ?(s as CodexState).transcript},
    restore: (s, saved) {
      if (saved['codexTranscript'] is String) (s as CodexState).transcript = saved['codexTranscript'] as String;
    },
  );
}
