// OpenCode: a plugin the office writes (see ../opencode.dart), loaded through OPENCODE_CONFIG_CONTENT,
// reports statuses and usage snapshots on /hooks/opencode. Ported from upstream's
// src/server/providers/opencode.ts.

import 'package:office_shared/shared.dart';

import '../opencode.dart';
import '../reported_usage.dart';
import 'provider.dart';

/// What a worker that reports statuses (OpenCode's plugin, Pi's extension) keeps of them.
class StatusState {
  /// An error keeps the desk visibly actionable until a new turn starts.
  bool error = false;
}

class OpenCodeSetup {
  const OpenCodeSetup({required this.plugin});

  final String plugin;
}

/// [args] without any `--model`/`-m` option, for an OpenCode launch that picks its own model (or
/// resumes a session, which keeps the one it had).
List<String> withoutOpenCodeModel(List<String> args) {
  final clean = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--model' || arg == '-m') {
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) i++;
      continue;
    }
    if (arg.startsWith('--model=') || (arg.startsWith('-m') && arg.length > 2)) continue;
    clean.add(arg);
  }
  return clean;
}

/// The status event in a plugin's (or Pi extension's) payload, when it is one.
OpenCodeStatusEvent? statusEvent(Object? v) {
  if (v is! Map) return null;
  final type = v['type'], sessionId = v['sessionId'];
  final status = OpenCodeHookStatus.tryParse(v['status']);
  if (type is! String || !OpenCodeStatusEvent.types.contains(type)) return null;
  if (sessionId is! String || sessionId.isEmpty || status == null || v['status'] is! String) return null;
  for (final k in ['prompt', 'tool', 'detail']) {
    if (v[k] != null && v[k] is! String) return null;
  }
  return OpenCodeStatusEvent(
    type: type,
    sessionId: sessionId,
    status: status,
    prompt: v['prompt'] as String?,
    tool: v['tool'] as String?,
    detail: v['detail'] as String?,
  );
}

/// OpenCode plugin callback. The plugin has already filtered child sessions before this bridge.
bool _openCodeHook(WorkerHandle h, String event, Object? payload) {
  final info = h.info;
  if (payload is Map && payload['type'] == 'usage') {
    final usage = reportedUsage(payload['usage']);
    if (usage == null || info.sessionId == null || payload['sessionId'] != info.sessionId) return false;
    // Full snapshots replace previous totals. They never advance task status or enter the Claude ledger.
    info.usage = usage;
    h.emit();
    h.persist();
    return true;
  }
  final ev = statusEvent(payload);
  return ev != null && reduceStatus(h, ev);
}

/// One status event for a worker. An event from another session is only taken when that session
/// starts, and the worker's task starts over with it. Says whether it was taken. [onReport]: each
/// event it takes, once its session is settled. [idleOnStart]: its session starting leaves it idle
/// whatever it was doing, not only while it was starting up.
bool reduceStatus(WorkerHandle h, OpenCodeStatusEvent ev, {void Function()? onReport, bool idleOnStart = false}) {
  final info = h.info;
  final state = h.state as StatusState;
  final starting = ev.type == 'session' && ev.status == OpenCodeHookStatus.starting;
  if (info.sessionId != null && info.sessionId != ev.sessionId && !starting) return false;
  if (info.sessionId == null || (starting && info.sessionId != ev.sessionId)) {
    final switching = info.sessionId != null;
    info.sessionId = ev.sessionId;
    if (switching) {
      info.usage = null;
      h.clearTask();
      info.activity = null;
      h.setStatus(WorkerStatus.idle);
    }
    state.error = false;
    h.persist();
  }
  onReport?.call();
  final prompt = ev.prompt;
  final hasPrompt = prompt != null && prompt.isNotEmpty;
  if (ev.type == 'error') {
    state.error = true;
  } else if (ev.status == OpenCodeHookStatus.working || hasPrompt) {
    state.error = false;
  }
  if (hasPrompt) {
    info.activity = truncateLine(prompt, 80);
    info.action = null;
    h.notePrompt(prompt);
  } else if (ev.tool != null && ev.tool!.isNotEmpty) {
    info.activity = truncateLine(ev.tool!, 80);
    info.action = toolAction(ev.tool);
  } else if (ev.detail != null && ev.detail!.isNotEmpty) {
    info.activity = truncateLine(ev.detail!, 80);
  }
  if (ev.status == OpenCodeHookStatus.needsInput) {
    h.setStatus(WorkerStatus.needsInput);
  } else if (ev.status == OpenCodeHookStatus.working) {
    h.setStatus(WorkerStatus.working);
  } else if (ev.status == OpenCodeHookStatus.done && h.running) {
    h.setStatus(state.error ? WorkerStatus.needsInput : WorkerStatus.done);
  } else if (ev.status == OpenCodeHookStatus.starting && (info.status == WorkerStatus.starting || idleOnStart)) {
    h.setStatus(WorkerStatus.idle);
  } else {
    h.emit();
  }
  return true;
}

class OpenCodeAdapter extends ProviderAdapter {
  const OpenCodeAdapter();

  @override
  AgentProvider get id => AgentProvider.opencode;

  @override
  Object? createState() => StatusState();

  @override
  Object? prepare(ProviderFloor floor) => OpenCodeSetup(plugin: writeOpenCodePlugin(floor.dataDir));

  @override
  LaunchPlan launch(LaunchInput input) {
    final info = input.h.info;
    final setup = input.setup as OpenCodeSetup;
    final resume = input.resumeSessionId;
    var args = input.args;
    if (resume != null || info.model != null) args = withoutOpenCodeModel(args);
    if (resume == null && info.model != null) args.addAll(['--model', info.model!]);
    if (resume != null) args.addAll(['--session', resume]);
    final prompt = input.prompt;
    if (prompt != null && prompt.isNotEmpty) args.addAll(['--prompt', prompt]);
    (input.h.state as StatusState).error = false;
    return LaunchPlan(
      args: args,
      rotateToken: true,
      finishEnv: (env) {
        env['AGENT_OFFICE_SESSION_ID'] = resume ?? '';
        env['OPENCODE_CONFIG_CONTENT'] = mergeOpenCodeConfigContent(
          env['OPENCODE_CONFIG_CONTENT'],
          openCodePluginSpecifier(setup.plugin),
        );
      },
    );
  }

  @override
  ProviderHook? get hook => const ProviderHook(strictJson: true, handle: _openCodeHook);

  @override
  AdapterUsage? get usage => const AdapterUsage(persisted: true);
}
