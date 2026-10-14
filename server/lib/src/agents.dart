import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

/// Finds the provider represented by the configured executable. Keep this deliberately based on
/// the final path component: --agent may be an absolute path, and Windows paths can be supplied
/// while the office itself is running under a POSIX shell. A Windows npm launcher (`pi.cmd`) counts
/// as its executable too.
AgentProvider configuredProvider(String command) {
  final base = p.posix
      .basename(command.replaceAll('\\', '/'))
      .toLowerCase()
      .replaceFirst(RegExp(r'\.(?:exe|cmd|bat|com)$'), '');
  for (final provider in agentProviderList) {
    if (providerMetaTable[provider]!.bin == base) return provider;
  }
  return AgentProvider.custom;
}

/// The providers an office started with [configured] can hire: the ones it knows, and a custom
/// --agent only when that's what it was started with.
List<AgentProvider> agentProviders(AgentProvider configured) => [
  for (final provider in agentProviderList)
    if (provider != AgentProvider.custom || configured == AgentProvider.custom) provider,
];

/// The command a provider's CLI runs as: the office's --agent when that's this provider, else its own executable.
String providerCommand(AgentProvider provider, String agentCmd) =>
    configuredProvider(agentCmd) == provider ? agentCmd : (providerMetaTable[provider]!.bin ?? agentCmd);

/// Why [model] can't be used for a worker of this kind and provider, or null when it can (or is absent).
String? validateWorkerModel(WorkerKind kind, AgentProvider? provider, Object? model) {
  if (model == null) return null;
  if (kind == WorkerKind.shell) return 'Shell workers do not have an agent model';
  final meta = providerMeta(provider);
  final valid = meta?.validModel;
  if (valid == null) return 'Models can only be selected for ${providerNames((m) => m.validModel != null)} workers';
  return valid(model) ? null : meta!.invalidModel;
}

/// A reasoning effort for a worker: a flag of its provider's CLI, an OpenCode model's variant, or
/// DSH's reasoning_effort configuration option. [effort] is an [AgentEffort], or its wire string.
String? validateWorkerEffort(WorkerKind kind, AgentProvider? provider, Object? effort) {
  if (effort == null) return null;
  if (kind == WorkerKind.shell) return 'Shell workers do not have a reasoning effort';
  if (!(providerMeta(provider)?.takesEffort ?? false)) {
    return 'Reasoning effort can only be selected for ${providerNames((m) => m.takesEffort)} workers';
  }
  return effort is AgentEffort || isAgentEffort(effort)
      ? null
      : 'Invalid effort (expected low, medium, high, xhigh or max)';
}
