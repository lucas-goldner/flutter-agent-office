// Cursor CLI: its hooks go in the hooks.json of the folder each worker runs in (see ../cursor.dart),
// since that and ~/.cursor, which the office never touches, are the only places it reads them from,
// and report on /hooks/cursor. It runs on the machine's own Cursor login. Its spend isn't metered by
// the office, and nothing tells the office about a permission prompt: a worker waiting on one shows
// as working until it's answered. Ported from upstream's src/server/providers/cursor.ts.

import 'package:office_shared/shared.dart';

import '../cursor.dart';
import '../lifecycle.dart';
import 'provider.dart';

class CursorSetup {
  const CursorSetup({required this.office});

  /// How its hooks run the office's own executable.
  final List<String> office;
}

bool _cursorHook(WorkerHandle h, String event, Object? payload) {
  final report = normalizeCursorHook(event, payload);
  if (report == null) return false;
  // A chat started over inside the terminal fires no sessionStart: its first prompt is the first the office hears of it.
  final session = h.info.sessionId;
  if (report.event == 'UserPromptSubmit' && session != null && session != report.sessionId) {
    reduceLifecycle(h, LifecycleReport(sessionId: report.sessionId, event: 'SessionStart', source: 'clear'));
  }
  return reduceLifecycle(h, report);
}

class CursorAdapter extends ProviderAdapter {
  const CursorAdapter();

  @override
  AgentProvider get id => AgentProvider.cursor;

  // What Cursor sets in its own shells. CURSOR_API_KEY stays: a worker signs in with it when it's set.
  @override
  List<String> get scrubEnv => const [
    'CURSOR_AGENT',
    'CURSOR_CLI',
    'CURSOR_INVOKED_AS',
    'CURSOR_CONVERSATION_ID',
    'CURSOR_REQUEST_ID',
  ];

  @override
  Object? prepare(ProviderFloor floor) => CursorSetup(office: floor.office);

  @override
  LaunchPlan launch(LaunchInput input) {
    final info = input.h.info;
    final setup = input.setup as CursorSetup;
    final args = withoutCursorLaunchArgs(input.args);
    addCursorHooks(input.cwd, setup.office, info.id);
    // The office made this folder for it. Cursor's own permission prompts stay as they are.
    args.add('--trust');
    // Its chat id is the first one its hooks name. A resumed chat keeps the model it had.
    final resume = input.resumeSessionId;
    if (resume != null) {
      args.add('--resume=$resume');
    } else if (info.model != null) {
      args.addAll(['--model', info.model!]);
    }
    final prompt = input.prompt;
    if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt]);
    return LaunchPlan(args: args, rotateToken: true);
  }

  @override
  void exited(WorkerHandle h, String cwd) => removeCursorHooks(cwd, h.info.id);

  @override
  RegExp? get titleNoise => RegExp(r'^cursor( agent| cli)?$', caseSensitive: false);

  @override
  ProviderHook? get hook => const ProviderHook(strictJson: true, handle: _cursorHook);

  // A resumed chat fires no sessionStart, so it's idle as soon as it runs; the login screen is read off its terminal.
  @override
  ScreenBlocked? get screenBlocked => cursorBlocked;
}
