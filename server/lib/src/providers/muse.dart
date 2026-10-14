// Muse Code: its settings and hooks live in XDG dirs of the office's own (see ../muse.dart), so a
// worker never edits ~/.config/muse, and report on /hooks/muse. Its spend isn't metered by the
// office. Ported from upstream's src/server/providers/muse.ts.

import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import '../lifecycle.dart';
import '../muse.dart';
import 'provider.dart';

class MuseAdapter extends ProviderAdapter {
  const MuseAdapter();

  @override
  AgentProvider get id => AgentProvider.muse;

  @override
  List<String> get scrubEnv => const ['MUSE_BIN', 'MUSE_AGENTS_THREAD', 'MUSE_AGENTS_ROLE', 'MUSE_PROJECTS_HOME'];

  @override
  Object? prepare(ProviderFloor floor) {
    final xdg = floor.env['XDG_CONFIG_HOME'];
    final userMuse = p.join(xdg != null && xdg.isNotEmpty ? xdg : p.join(homeOf(floor.env), '.config'), 'muse');
    return writeMuseHome(floor.dataDir, floor.office, Directory(userMuse).existsSync() ? userMuse : null);
  }

  @override
  LaunchPlan launch(LaunchInput input) {
    final h = input.h;
    final info = h.info;
    final setup = input.setup as MuseHome;
    final args = withoutMuseLaunchArgs(input.args)..add('--trust-workspace');
    final prompt = input.prompt;
    final resume = input.resumeSessionId;
    if (resume != null) {
      args.addAll(['resume', resume]);
      // Muse resume cannot take a prompt on argv: it's pasted into the TUI after SessionStart.
      h.pendingPrompt = prompt != null && prompt.isNotEmpty ? prompt : null;
    } else {
      if (info.model != null) args.addAll(['--model', info.model!]);
      if (info.effort != null) args.addAll(['--reasoning-effort', info.effort!.wire]);
      if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt]);
    }
    return LaunchPlan(
      args: args,
      rotateToken: true,
      env: {'XDG_CONFIG_HOME': setup.configHome, 'XDG_DATA_HOME': setup.dataHome, 'XDG_STATE_HOME': setup.stateHome},
    );
  }

  @override
  String? get bootHint => 'Open the terminal: complete login if Muse asks';

  @override
  RegExp? get titleNoise => RegExp(r'^muse( code)?$', caseSensitive: false);

  @override
  ProviderHook? get hook => ProviderHook(
    strictJson: true,
    handle: (h, event, payload) {
      final report = normalizeMuseHook(event, payload);
      return report != null && reduceLifecycle(h, report);
    },
  );
}
