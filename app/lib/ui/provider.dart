// Which agent runs at a desk, and whether the office can count what it spends: the parts of
// ui/provider.ts the HUD needs (the picker widget lives with the prompt window).

import '../shared/protocol.dart';

const Map<AgentProvider, String> providerNames = {
  AgentProvider.claude: 'Claude Code',
  AgentProvider.opencode: 'OpenCode',
  AgentProvider.codex: 'Codex',
  AgentProvider.custom: 'Custom',
};

/// Providers the server says this project can start.
List<AgentProvider> supportedProviders(ProjectInfo? project) {
  final values = project?.agentProviders ?? const [];
  if (values.isNotEmpty) return values.toSet().toList();
  return project != null ? [project.defaultProvider] : [AgentProvider.claude];
}

/// Resolve old workers/tasks that have no provider metadata to the configured default.
AgentProvider resolvedProvider(AgentProvider? provider, ProjectInfo? project) {
  // A worker/task keeps its identity even if the office was later restarted with a
  // configuration that no longer offers that provider.
  if (provider != null) return provider;
  return project?.defaultProvider ?? supportedProviders(project).first;
}

String providerLabel(AgentProvider? provider, ProjectInfo? project) =>
    providerNames[resolvedProvider(provider, project)]!;

bool providerUsageTracked(AgentProvider? provider, ProjectInfo? project, [Usage? usage]) =>
    resolvedProvider(provider, project) == AgentProvider.claude || usage != null;

enum ProviderUsageState { tracked, waiting, untracked }

/// Distinguishes a provider with no first report from one whose metrics are intentionally unavailable.
ProviderUsageState providerUsageState(AgentProvider? provider, ProjectInfo? project, [Usage? usage]) {
  if (usage != null) return ProviderUsageState.tracked;
  return resolvedProvider(provider, project) == AgentProvider.custom
      ? ProviderUsageState.untracked
      : ProviderUsageState.waiting;
}

String providerUsageNote(AgentProvider provider) => switch (provider) {
  AgentProvider.claude => 'Office usage and budget track Claude Code.',
  AgentProvider.codex => 'Review Office hooks in /hooks to enable tracking. Codex reports root-session tokens; subagents are excluded and cost is unavailable.',
  AgentProvider.custom => 'Usage is untracked unless compatible Claude Code hooks report it.',
  AgentProvider.opencode =>
    'OpenCode reports model/provider estimates; they are not billing, and arrive after the first report.',
};
