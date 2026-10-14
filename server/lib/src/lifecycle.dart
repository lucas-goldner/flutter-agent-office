// The turn-by-turn life of an agent as its hooks tell it: its session starting, prompts, tool calls,
// questions and permission prompts, and the end of each turn. Grok, Muse, Cursor and Codex report
// theirs as compacted events (see grok.dart, muse.dart, cursor.dart and codex.dart) that all run
// through one reducer here, Codex following its tool calls one by one; Claude Code's own hook is built
// from the same steps (see providers/claude.dart). OpenCode's plugin reports statuses instead (see
// providers/opencode.dart). Ported from upstream's src/server/workers/lifecycle.ts.

import 'package:office_shared/shared.dart';

import 'worker_handle.dart';

/// A permission prompt this soon after the worker stopped needing input is the late one for what was just answered.
const latePromptGraceMs = 5000;

/// Tools that ask the person something: the worker needs input until they're answered.
final _asks = RegExp(r'(?:^|[._])(?:AskUserQuestion|ask_user_question|request_user_input)$');

/// In the middle of a turn: working, or asking something (not stuck on a trust or login screen).
bool midTurn(LiveInfo info, bool bootBlocked) =>
    info.kind == WorkerKind.agent &&
    (info.status == WorkerStatus.working || (info.status == WorkerStatus.needsInput && !bootBlocked));

/// A lifecycle hook event as a provider's normalizer compacts it.
class LifecycleReport {
  const LifecycleReport({
    required this.sessionId,
    required this.event,
    this.source,
    this.prompt,
    this.tool,
    this.toolUseId,
    this.notificationType,
    this.reason,
  });

  final String sessionId;
  final String event;
  final String? source;
  final String? prompt;
  final String? tool;
  final String? toolUseId;
  final String? notificationType;

  /// Why a turn stopped, when it says.
  final String? reason;

  Map<String, Object> toJson() => {
    'sessionId': sessionId,
    'event': event,
    'source': ?source,
    'prompt': ?prompt,
    'tool': ?tool,
    'toolUseId': ?toolUseId,
    'notificationType': ?notificationType,
    'reason': ?reason,
  };

  /// What a hook helper posts to the office for it: the bounded fields only, as the agent's hooks
  /// name them (see hook.dart).
  Map<String, Object> hookBody() => {
    'session_id': sessionId,
    'hook_event_name': event,
    'source': ?source,
    'prompt': ?prompt,
    'tool_name': ?tool,
    'tool_use_id': ?toolUseId,
    'notification_type': ?notificationType,
    'reason': ?reason,
  };
}

/// [value] trimmed, when it's a string of 1 to [max] characters.
String? boundedText(Object? value, int max) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isNotEmpty && text.length <= max ? text : null;
}

/// [value] is a string with something in it.
bool hasText(Object? value) => value is String && value.trim().isNotEmpty;

/// The first of [keys] that [payload] has (camelCase or snake_case spellings of one field).
Object? pickField(Map payload, List<String> keys) {
  for (final key in keys) {
    if (payload.containsKey(key)) return payload[key];
  }
  return null;
}

/// Tool calls followed one by one, for a provider whose hooks never say a question was answered
/// (Codex): a call that asked the person something, or wanted permission, keeps the worker needing
/// input until that call is over.
abstract interface class ToolTracker {
  /// A new session or turn, or the turn ended: nothing is pending any more.
  void clear();
  void started(String? tool, String? toolUseId);
  void permission(String? tool);
  void finished(String? toolUseId);

  /// Some call is waiting on the person.
  bool waiting();
}

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Notification: a permission prompt needs the person (unless it's the late one for what was just
/// answered), the idle prompt ends a turn.
void notified(WorkerHandle h, Object? type, [int? now]) {
  if (type == 'permission_prompt') {
    if ((now ?? _now()) - h.leftNeedsInputAt > latePromptGraceMs) h.setStatus(WorkerStatus.needsInput);
  } else if (type == 'idle_prompt') {
    if (h.info.status == WorkerStatus.working) h.setStatus(WorkerStatus.done);
  }
}

/// A tool call ended: if it was waiting on the person, it has its answer and the worker carries on.
void answered(WorkerHandle h, [int? now]) {
  if (h.info.status == WorkerStatus.needsInput) {
    h.leftNeedsInputAt = now ?? _now();
    h.setStatus(WorkerStatus.working);
  }
}

/// It wants permission for [what].
void wantsPermission(WorkerHandle h, String what) {
  h.info.activity = 'Wants permission: $what';
  h.setStatus(WorkerStatus.needsInput);
}

/// One compacted hook event for a worker. An event from another session is only taken when that
/// session starts (a /clear, say), and the worker's task starts over with it. Says whether it was taken.
/// [onSessionSwitch]: another session replaced the one the worker had, and its task was cleared.
/// [onReport]: each event it takes, once its session is settled. [tools]: follow tool calls one by
/// one (see [ToolTracker]) instead of going by the tool's name alone.
bool reduceLifecycle(
  WorkerHandle h,
  LifecycleReport report, {
  void Function()? onSessionSwitch,
  void Function()? onReport,
  ToolTracker? tools,
}) {
  final info = h.info;
  if (info.sessionId != null && info.sessionId != report.sessionId && report.event != 'SessionStart') return false;
  if (info.sessionId == null || info.sessionId != report.sessionId) {
    if (info.sessionId != null) {
      h.clearTask();
      onSessionSwitch?.call();
    }
    info.sessionId = report.sessionId;
    h.persist();
  }
  onReport?.call();
  h.bootBlocked = false;
  void busy() => h.setStatus(tools != null && tools.waiting() ? WorkerStatus.needsInput : WorkerStatus.working);
  switch (report.event) {
    case 'SessionStart':
      tools?.clear();
      if (report.source == 'clear') h.clearTask();
      info.activity = null;
      if (info.status == WorkerStatus.starting || info.status == WorkerStatus.needsInput) {
        h.setStatus(WorkerStatus.idle);
      }
      // A prompt its start couldn't take on the command line (a Muse resume): now it can.
      final pending = h.pendingPrompt;
      if (pending != null) {
        h.pendingPrompt = null;
        h.prompt(pending);
      }
    case 'UserPromptSubmit':
      tools?.clear();
      info.action = null;
      final prompt = report.prompt;
      if (prompt != null && prompt.isNotEmpty) {
        info.activity = truncateLine(prompt, 80);
        h.notePrompt(prompt);
      }
      h.setStatus(WorkerStatus.working);
    case 'PreToolUse':
      final tool = report.tool;
      final activity = tool != null && tool.isNotEmpty ? truncateLine(tool, 80) : 'Using a tool';
      info.activity = activity;
      info.action = toolAction(tool);
      h.noteTool(activity);
      if (tools != null) {
        tools.started(tool, report.toolUseId);
        busy();
      } else if (_asks.hasMatch(tool ?? '')) {
        h.setStatus(WorkerStatus.needsInput);
      } else if (info.status != WorkerStatus.working) {
        h.setStatus(WorkerStatus.working);
      } else {
        h.emit();
      }
    case 'PermissionRequest':
      tools?.permission(report.tool);
      wantsPermission(h, truncateLine(report.tool ?? 'tool', 80));
    case 'PostToolUse':
    case 'PostToolUseFailure':
      if (tools != null) {
        tools.finished(report.toolUseId);
        busy();
      } else {
        answered(h);
      }
    case 'Notification':
      notified(h, report.notificationType);
    case 'Stop':
    case 'StopFailure':
    case 'StopCancelled':
    case 'Interrupt':
      tools?.clear();
      h.setStatus(WorkerStatus.done);
  }
  h.emit();
  h.persist();
  return true;
}
