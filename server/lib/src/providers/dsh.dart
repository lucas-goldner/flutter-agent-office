// DeepSeek Harness: no terminal and no hooks. The office holds an ACP connection to it and draws
// its updates into the worker's terminal itself (see ../dsh.dart and docs/dsh-acp-integration.md).
// Ported from upstream's src/server/providers/dsh.ts.

import 'package:office_shared/shared.dart';

import '../dsh.dart';
import 'provider.dart';

class DshSetup {
  const DshSetup({required this.dataDir, required this.profile});

  final String dataDir;
  final String profile;
}

class DshAdapter extends ProviderAdapter {
  const DshAdapter();

  @override
  AgentProvider get id => AgentProvider.dsh;

  @override
  Object? prepare(ProviderFloor floor) => DshSetup(dataDir: floor.dataDir, profile: floor.dshProfile);

  // No argv for prompts or resume: those go over ACP.
  @override
  LaunchPlan launch(LaunchInput input) {
    final setup = input.setup as DshSetup;
    return LaunchPlan(
      args: dshArgs(profile: setup.profile, patches: [writeDshPatch(setup.dataDir)], extra: input.args),
      env: {'AGENT_OFFICE_DSH_PROFILE': setup.profile},
    );
  }

  @override
  ProviderTransport get transport => ProviderTransport.acp;

  @override
  AdapterUsage? get usage => const AdapterUsage(persisted: true);
}
