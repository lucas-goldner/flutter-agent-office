// Pi: an extension the office writes and loads with --extension (see ../pi.dart), so the person's own
// Pi login, settings, packages and extensions stay as they are. It reports on /hooks/pi in the same
// statuses as OpenCode's plugin. Each desk keeps its sessions in a folder of its own, so a worker
// never resumes another's conversation. Its spend isn't metered by the office. Ported from upstream's
// src/server/providers/pi.ts.

import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import '../pi.dart';
import 'opencode.dart';
import 'provider.dart';

class PiSetup {
  const PiSetup({required this.extension, required this.dataDir});

  /// The office's extension.
  final String extension;

  /// Where each desk's session folder goes (`pi-sessions/<worker id>`).
  final String dataDir;
}

class PiAdapter extends ProviderAdapter {
  const PiAdapter();

  @override
  AgentProvider get id => AgentProvider.pi;

  @override
  Object? createState() => StatusState();

  @override
  Object? prepare(ProviderFloor floor) => PiSetup(extension: writePiExtension(floor.dataDir), dataDir: floor.dataDir);

  @override
  LaunchPlan launch(LaunchInput input) {
    final h = input.h;
    final info = h.info;
    final setup = input.setup as PiSetup;
    final sessionDir = p.join(setup.dataDir, 'pi-sessions', info.id);
    Directory(sessionDir).createSync(recursive: true);
    (h.state as StatusState).error = false;
    // --session-id picks up the desk's own conversation, even one Pi hadn't written to disk yet.
    return LaunchPlan(
      args: piArgs(
        input.args,
        extension: setup.extension,
        sessionDir: sessionDir,
        sessionId: input.resumeSessionId,
        model: info.model,
        effort: info.effort,
        prompt: input.prompt,
      ),
      rotateToken: true,
    );
  }

  @override
  String? get bootHint => 'Open the terminal: complete Pi login or project setup';

  @override
  ProviderHook? get hook => ProviderHook(
    strictJson: true,
    handle: (h, event, payload) {
      final report = normalizePiHook(payload);
      // Pi is up once its extension reports, so the desk isn't stuck at start any more. A session
      // starting (a new one, or one resumed) leaves it ready for a prompt.
      return report != null && reduceStatus(h, report, onReport: () => h.bootBlocked = false, idleOnStart: true);
    },
  );
}
