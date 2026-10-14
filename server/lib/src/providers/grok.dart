// Grok: its hooks live in a GROK_HOME of the office's own (see ../grok.dart), so a worker never
// edits ~/.grok, and report on /hooks/grok. Its spend isn't metered by the office. Ported from
// upstream's src/server/providers/grok.ts.

import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import '../grok.dart';
import '../lifecycle.dart';
import 'provider.dart';

class GrokSetup {
  const GrokSetup({required this.home, required this.socket, this.authPath});

  final String home;
  final String socket;

  /// The person's own Grok sign-in, when there is one.
  final String? authPath;
}

class GrokAdapter extends ProviderAdapter {
  const GrokAdapter();

  @override
  AgentProvider get id => AgentProvider.grok;

  @override
  List<String> get scrubEnv => const [
    'GROK_SESSION_ID', 'GROK_AGENT_ID', 'GROK_HOOK_EVENT', 'GROK_HOOK_NAME', 'GROK_WORKSPACE_ROOT', //
    'GROK_PLUGIN_ROOT', 'GROK_PLUGIN_DATA', 'GROK_AUTH', 'GROK_AUTH_PATH',
  ];

  @override
  Object? prepare(ProviderFloor floor) {
    final home = writeGrokHome(floor.dataDir, floor.office);
    final configured = floor.env['GROK_HOME'];
    final userGrok = configured != null && configured.isNotEmpty ? configured : p.join(homeOf(floor.env), '.grok');
    final auth = p.join(userGrok, 'auth.json');
    return GrokSetup(home: home.home, socket: home.socket, authPath: File(auth).existsSync() ? auth : null);
  }

  @override
  LaunchPlan launch(LaunchInput input) {
    final info = input.h.info;
    final setup = input.setup as GrokSetup;
    final args = withoutGrokLaunchArgs(input.args)
      ..addAll(['--no-alt-screen', '--trust', '--leader-socket', setup.socket]);
    final resume = input.resumeSessionId;
    if (resume != null) {
      args.addAll(['--resume', resume]);
    } else {
      final session = info.sessionId ??= randomUuid();
      args.addAll(['--session-id', session]);
      if (info.model != null) args.addAll(['--model', info.model!]);
      if (info.effort != null) args.addAll(['--effort', info.effort!.wire]);
    }
    final prompt = input.prompt;
    if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt]);
    return LaunchPlan(args: args, rotateToken: true, env: {'GROK_HOME': setup.home, 'GROK_AUTH_PATH': ?setup.authPath});
  }

  @override
  String? get bootHint => 'Open the terminal: complete login if Grok asks';

  @override
  RegExp? get titleNoise => RegExp(r'^grok( build)?$', caseSensitive: false);

  @override
  ProviderHook? get hook => ProviderHook(
    strictJson: true,
    handle: (h, event, payload) {
      final report = normalizeGrokHook(event, payload);
      return report != null && reduceLifecycle(h, report);
    },
  );
}
