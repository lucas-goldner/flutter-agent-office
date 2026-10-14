import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

/// Finds the provider represented by the configured executable. Keep this deliberately based on
/// the final path component: --agent may be an absolute path, and Windows paths can be supplied
/// while the office itself is running under a POSIX shell.
AgentProvider configuredProvider(String command) {
  final base = p.posix.basename(command.replaceAll('\\', '/')).toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
  if (base == 'claude') return AgentProvider.claude;
  if (base == 'opencode') return AgentProvider.opencode;
  if (base == 'codex') return AgentProvider.codex;
  return AgentProvider.custom;
}

/// Why [model] can't be used for a worker of this kind and provider, or null when it can (or is absent).
/// [kind] is 'agent' or 'shell'; [model] null means none was requested.
String? validateWorkerModel(WorkerKind kind, AgentProvider? provider, Object? model) {
  if (model == null) return null;
  if (kind == WorkerKind.shell) return 'Shell workers do not have an agent model';
  if (provider == AgentProvider.claude) {
    return isClaudeModel(model) ? null : 'Invalid Claude model (expected fable, opus, sonnet or haiku)';
  }
  if (provider != AgentProvider.opencode) return 'Models can only be selected for Claude Code or OpenCode workers';
  if (!isValidOpenCodeModel(model)) return 'Invalid OpenCode model (expected provider/model without whitespace)';
  return null;
}

/// Claude Code's own `--effort` flag; no other provider this office launches supports one yet.
/// [effort] is what was asked for (an [AgentEffort], or its wire string), null for none.
String? validateWorkerEffort(WorkerKind kind, AgentProvider? provider, Object? effort) {
  if (effort == null) return null;
  if (kind == WorkerKind.shell) return 'Shell workers do not have a reasoning effort';
  if (provider != AgentProvider.claude) return 'Reasoning effort can only be selected for Claude Code workers';
  return effort is AgentEffort || isAgentEffort(effort)
      ? null
      : 'Invalid effort (expected low, medium, high, xhigh or max)';
}

/// The providers an office started with [configured] can hire: the three it knows, and a custom
/// --agent only when that's what it was started with.
List<AgentProvider> agentProviders(AgentProvider configured) => configured == AgentProvider.custom
    ? const [AgentProvider.claude, AgentProvider.opencode, AgentProvider.codex, AgentProvider.custom]
    : const [AgentProvider.claude, AgentProvider.opencode, AgentProvider.codex];
