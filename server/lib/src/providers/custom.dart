// A custom --agent: the office runs it as it is. It reports on Claude Code's hook route when it
// speaks Claude Code's hooks, and is read like Claude Code's screen and transcript. Ported from
// upstream's src/server/providers/custom.ts.

import 'package:office_shared/shared.dart';

import 'claude.dart';
import 'provider.dart';

class CustomAdapter extends ProviderAdapter {
  const CustomAdapter();

  @override
  AgentProvider get id => AgentProvider.custom;

  @override
  LaunchPlan launch(LaunchInput input) => LaunchPlan(args: input.args);

  @override
  AgentProvider? get hooksAs => AgentProvider.claude;

  @override
  ScreenBlocked? get screenBlocked => claudeBlocked;

  @override
  AdapterUsage? get usage => const AdapterUsage(transcript: true);

  @override
  bool get namesTasks => true;
}
