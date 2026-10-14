// Every agent provider's adapter (see provider.dart). Adding a provider: its adapter file, one line
// here and its entry in office_shared's providers.dart. Ported from upstream's
// src/server/providers/index.ts and src/server/workers/env.ts.

import 'dart:io';

import 'package:office_shared/shared.dart';

import 'claude.dart';
import 'codex.dart';
import 'cursor.dart';
import 'custom.dart';
import 'dsh.dart';
import 'grok.dart';
import 'muse.dart';
import 'opencode.dart';
import 'pi.dart';
import 'provider.dart';

export 'claude.dart';
export 'codex.dart';
export 'cursor.dart';
export 'custom.dart';
export 'dsh.dart';
export 'grok.dart';
export 'muse.dart';
export 'opencode.dart';
export 'pi.dart';
export 'provider.dart';

const Map<AgentProvider, ProviderAdapter> providerAdapters = {
  AgentProvider.claude: ClaudeAdapter(),
  AgentProvider.opencode: OpenCodeAdapter(),
  AgentProvider.codex: CodexAdapter(),
  AgentProvider.grok: GrokAdapter(),
  AgentProvider.muse: MuseAdapter(),
  AgentProvider.dsh: DshAdapter(),
  AgentProvider.pi: PiAdapter(),
  AgentProvider.cursor: CursorAdapter(),
  AgentProvider.custom: CustomAdapter(),
};

/// The adapter of [provider], when it's one (workers.json and the wire can hold anything): an
/// [AgentProvider], or its wire spelling.
ProviderAdapter? providerAdapter(Object? provider) {
  final p = provider is AgentProvider ? provider : AgentProvider.tryParse(provider);
  return p == null ? null : providerAdapters[p];
}

/// The hook route /hooks/[route] serves, when it's one (see [ProviderAdapter.hook]).
ProviderHook? providerHook(String route) => providerAdapter(route)?.hook;

/// A terminal title that's only an agent's own name ("Claude Code"): not worth showing, whichever
/// agent the worker runs.
bool titleNoise(String title) => providerAdapters.values.any((p) => p.titleNoise?.hasMatch(title) ?? false);

// Env vars from a parent agent session (e.g. starting the office from inside Claude Code) that
// would make a worker think it is a child session — that silently turns off transcript saving,
// which breaks resume. Each provider names its own (see ProviderAdapter.scrubEnv).
final Set<String> _scrubEnv = {
  for (final a in providerAdapters.values) ...a.scrubEnv,
  'NO_COLOR', 'FORCE_COLOR', 'VSCODE_INJECTION', 'TERM_PROGRAM', 'TERM_PROGRAM_VERSION', //
};
final List<String> _scrubPrefixes = [
  for (final a in providerAdapters.values) ...a.scrubPrefixes,
  'NEBULA_',
  'AGENT_OFFICE_',
];
bool _scrubbed(String k) => _scrubEnv.contains(k) || _scrubPrefixes.any(k.startsWith);

/// The office's environment (or [base]), minus anything that would make a child think it's a nested session.
Map<String, String> childEnv([Map<String, String>? base]) => {
  for (final e in (base ?? Platform.environment).entries)
    if (!_scrubbed(e.key)) e.key: e.value,
};
