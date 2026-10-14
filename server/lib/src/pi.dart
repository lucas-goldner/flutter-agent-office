// Pi: its command line (a session folder per desk, the office's extension) and the extension that
// reports its lifecycle on /hooks/pi, in the same statuses as OpenCode's plugin (see providers/pi.dart).
// Pi is a Node CLI and loads the extension itself, so it stays JavaScript. Ported from upstream's
// src/server/pi.ts.

import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'opencode.dart';
import 'providers/provider.dart' show writePrivate;

/// A Pi session id, as Pi itself accepts one for --session-id.
final _piSessionId = RegExp(r'^[A-Za-z0-9._-]{1,160}$');

/// Keep sessions per desk; do not resume another worker's most recent conversation.
List<String> piArgs(
  List<String> extra, {
  required String extension,
  required String sessionDir,
  String? sessionId,
  String? model,
  AgentEffort? effort,
  String? prompt,
}) {
  final values = {'--mode', '--session', '--session-dir', '--session-id', '--fork', '--export'};
  const flags = {'--print', '-p', '--continue', '-c', '--resume', '-r', '--no-session'};
  final hasModel = model != null && model.isNotEmpty;
  if (hasModel) values.add('--model');
  // A provider-qualified selection must override the configured CLI provider too.
  if (hasModel && model.contains('/')) values.add('--provider');
  if (effort != null) values.add('--thinking');
  final args = <String>[];
  for (var i = 0; i < extra.length; i++) {
    final arg = extra[i];
    if (arg == '--') break;
    if (flags.contains(arg)) continue;
    if (values.contains(arg)) {
      i++;
      continue;
    }
    if (values.any((name) => arg.startsWith('$name='))) continue;
    args.add(arg);
  }
  args.addAll(['--session-dir', sessionDir, '--extension', extension]);
  // Pi doesn't write a session file until the first assistant reply. --session-id resumes persisted
  // history and also reopens an unused desk with the same id.
  if (sessionId != null && sessionId.isNotEmpty) args.addAll(['--session-id', sessionId]);
  if (hasModel) args.addAll(['--model', model]);
  if (effort != null) args.addAll(['--thinking', effort.wire]);
  // Pi reads an argument starting with '@' as a file to include, even after --: a prompt is only ever text.
  if (prompt != null && prompt.isNotEmpty) args.addAll(['--', prompt.startsWith('@') ? ' $prompt' : prompt]);
  return args;
}

/// Accept only bounded lifecycle fields, never assistant text, tool arguments, or credentials.
OpenCodeStatusEvent? normalizePiHook(Object? value) {
  if (value is! Map) return null;
  bool bounded(Object? text, int max) =>
      text is String &&
      text.isNotEmpty &&
      text.length <= max &&
      !RegExp(r'[\p{Cc}\p{Cf}]', unicode: true).hasMatch(text);
  final sessionId = value['sessionId'];
  if (sessionId is! String || !_piSessionId.hasMatch(sessionId)) return null;
  final type = value['type'];
  if (type is! String || !const {'session', 'prompt', 'tool', 'question', 'error'}.contains(type)) return null;
  final status = OpenCodeHookStatus.tryParse(value['status']);
  if (status == null) return null;
  final prompt = value['prompt'];
  if (value.containsKey('prompt') && (prompt is! String || prompt.length > 20000)) return null;
  final tool = value['tool'];
  if (value.containsKey('tool') && !bounded(tool, 160)) return null;
  return OpenCodeStatusEvent(
    type: type,
    sessionId: sessionId,
    status: status,
    prompt: prompt is String ? prompt : null,
    tool: tool is String ? tool : null,
  );
}

/// A CLI-loaded extension preserves the user's Pi config, auth, packages, and extensions.
String writePiExtension(String dataDir) {
  Directory(dataDir).createSync(recursive: true);
  final file = p.join(dataDir, 'agent-office-pi-extension.mjs');
  writePrivate(file, piExtensionSource);
  return file;
}

const piExtensionSource = r'''export default function (pi) {
  const worker = process.env.AGENT_OFFICE_WORKER_ID;
  const token = process.env.AGENT_OFFICE_HOOK_TOKEN;
  const hook = process.env.AGENT_OFFICE_HOOK_URL;
  if (!worker || !token || !hook) return;
  let url;
  try {
    url = new URL('/hooks/pi', hook);
    if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1') return;
    url.searchParams.set('worker', worker);
  } catch { return; }
  // Serialize requests so a slow working event cannot overwrite a later done event.
  let pending = Promise.resolve();
  const send = (ctx, type, status, fields = {}) => {
    const sessionId = ctx.sessionManager.getSessionId();
    const body = JSON.stringify({ sessionId, type, status, ...fields });
    pending = pending.then(async () => {
      try {
        await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token }, body, signal: AbortSignal.timeout(1500) });
      } catch { /* Office connectivity never interrupts Pi. */ }
    });
    return pending;
  };
  pi.on('session_start', (_event, ctx) => send(ctx, 'session', 'starting'));
  pi.on('before_agent_start', (event, ctx) => send(ctx, 'prompt', 'working', { prompt: event.prompt.slice(0, 20000) }));
  pi.on('agent_start', (_event, ctx) => send(ctx, 'session', 'working'));
  pi.on('tool_execution_start', (event, ctx) => send(ctx, 'tool', 'working', { tool: event.toolName.slice(0, 160) }));
  pi.on('tool_execution_end', (event, ctx) => {
    if (event.isError) return send(ctx, 'tool', 'working', { tool: event.toolName.slice(0, 160) });
  });
  pi.on('message_end', (event, ctx) => {
    if (event.message.role === 'assistant' && event.message.stopReason === 'error') return send(ctx, 'error', 'working');
  });
  pi.on('ui_prompt_start', (_event, ctx) => send(ctx, 'question', 'needs_input'));
  pi.on('ui_prompt_end', (_event, ctx) => send(ctx, 'session', ctx.isIdle() ? 'done' : 'working'));
  // agent_end can precede retries/compaction; settled is the actual end of the task.
  pi.on('agent_settled', (_event, ctx) => send(ctx, 'session', 'done'));
  pi.on('session_shutdown', () => pending);
}
''';
