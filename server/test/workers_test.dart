@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/hook.dart' show officeCommand;
import 'package:agent_office_server/src/prompts.dart';
import 'package:agent_office_server/src/signins.dart';
import 'package:agent_office_server/src/usage.dart';
import 'package:agent_office_server/src/workers.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// One run of a fake provider CLI, as it logged itself.
class Invocation {
  Invocation(Map<String, dynamic> j)
    : kind = j['kind'] as String,
      args = [for (final a in j['args'] as List) a as String],
      stdin = j['stdin'] as String?,
      env = {for (final e in (j['env'] as Map).entries) e.key as String: e.value as String};

  final String kind;
  final List<String> args;
  final String? stdin;
  final Map<String, String> env;

  String? get workerId => env['workerId'];
  String? get hookToken => env['hookToken'];
  String? get opencodeConfig => env['opencodeConfig'];
  String? get path => env['path'];
}

class Fixture {
  Fixture._(this.root)
    : data = p.join(root, 'data'),
      bin = p.join(root, 'bin'),
      log = p.join(root, 'invocations.jsonl');

  factory Fixture() {
    final f = Fixture._(Directory.systemTemp.createTempSync('agent-office-workers-').path);
    Directory(f.data).createSync(recursive: true);
    Directory(f.bin).createSync(recursive: true);
    for (final name in ['claude', 'opencode', 'custom-agent', 'codex', 'grok', 'muse', 'cursor-agent']) {
      final file = p.join(f.bin, name);
      File(file).writeAsStringSync(_fakeAgent);
      Process.runSync('chmod', ['700', file]);
    }
    File(f.log).writeAsStringSync('');
    return f;
  }

  final String root;
  final String data;
  final String bin;
  final String log;
  String get claude => p.join(bin, 'claude');
  String get opencode => p.join(bin, 'opencode');
  String get codex => p.join(bin, 'codex');
  String get custom => p.join(bin, 'custom-agent');

  List<Invocation> read() {
    final file = File(log);
    if (!file.existsSync()) return [];
    return [
      for (final line in file.readAsStringSync().split('\n'))
        if (line.isNotEmpty) Invocation(jsonDecode(line) as Map<String, dynamic>),
    ];
  }

  /// Deletes it all. A worker still winding down may write its state meanwhile: try again then.
  Future<void> close() async {
    for (var i = 0; i < 20; i++) {
      try {
        Directory(root).deleteSync(recursive: true);
        return;
      } on PathNotFoundException {
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

/// Logs how it was started (and each line typed into it) to $FAKE_AGENT_LOG as JSON. Stands in for
/// every provider CLI, and for the task namer's non-interactive Claude call.
const _fakeAgent = r'''#!/bin/bash
kind=${0##*/}
esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  s=${s//$'\e'/\\u001b}
  printf '%s' "$s"
}
args=""
for a in "$@"; do args+="${args:+,}\"$(esc "$a")\""; done
envjson() {
  local out=""
  [ -n "${AGENT_OFFICE_WORKER_ID+x}" ] && out+=",\"workerId\":\"$(esc "$AGENT_OFFICE_WORKER_ID")\""
  [ -n "${AGENT_OFFICE_HOOK_TOKEN+x}" ] && out+=",\"hookToken\":\"$(esc "$AGENT_OFFICE_HOOK_TOKEN")\""
  [ -n "${AGENT_OFFICE_HOOK_URL+x}" ] && out+=",\"hookUrl\":\"$(esc "$AGENT_OFFICE_HOOK_URL")\""
  [ -n "${OPENCODE_CONFIG_CONTENT+x}" ] && out+=",\"opencodeConfig\":\"$(esc "$OPENCODE_CONFIG_CONTENT")\""
  [ -n "${PATH+x}" ] && out+=",\"path\":\"$(esc "$PATH")\""
  [ -n "${GROK_HOME+x}" ] && out+=",\"grokHome\":\"$(esc "$GROK_HOME")\""
  [ -n "${XDG_CONFIG_HOME+x}" ] && out+=",\"xdgConfig\":\"$(esc "$XDG_CONFIG_HOME")\""
  [ -n "${XDG_DATA_HOME+x}" ] && out+=",\"xdgData\":\"$(esc "$XDG_DATA_HOME")\""
  [ -n "${XDG_STATE_HOME+x}" ] && out+=",\"xdgState\":\"$(esc "$XDG_STATE_HOME")\""
  [ -n "${CLAUDE_CONFIG_DIR+x}" ] && out+=",\"claudeConfig\":\"$(esc "$CLAUDE_CONFIG_DIR")\""
  [ -n "${GH_CONFIG_DIR+x}" ] && out+=",\"ghConfig\":\"$(esc "$GH_CONFIG_DIR")\""
  [ -n "${ANTHROPIC_API_KEY+x}" ] && out+=",\"apiKey\":\"$(esc "$ANTHROPIC_API_KEY")\""
  printf '{%s}' "${out#,}"
}
record() {
  printf '{"kind":"%s","args":[%s]%s,"env":%s}\n' "$kind" "$args" "$1" "$(envjson)" >> "$FAKE_AGENT_LOG"
}
record ""

# The task namer invokes Claude as a non-interactive JSON command. Keep that
# invocation deterministic and separate from the worker's real PTY process.
for a in "$@"; do
  if [ "$a" = "--output-format" ]; then
    printf '%s' '{"structured_output":{"name":"Fake Task","summary":"Recording a deterministic test task"}}'
    exit 0
  fi
done

printf 'fake-agent-ready\r\n'
trap 'exit 0' TERM
delay=${FAKE_AGENT_EXIT_MS:-0}
if [ "$delay" -gt 0 ]; then
  ( sleep "$(printf '%d.%03d' $((delay / 1000)) $((delay % 1000)))"; kill -TERM $$ 2>/dev/null ) &
fi
while IFS= read -r line; do record ",\"stdin\":\"$(esc "$line")\""; done
''';

final _credential = RegExp(
  r'(?:API_KEY|AUTH_TOKEN|ACCESS_TOKEN|SECRET|PASSWORD|CREDENTIAL|TOKEN)',
  caseSensitive: false,
);

/// Keep provider CLIs in this test fixture from seeing a user's config or credentials.
Map<String, String> isolatedEnv(Fixture f, [Map<String, String> extra = const {}]) {
  final env = <String, String>{};
  for (final e in Platform.environment.entries) {
    // Delete by variable name only. Do not read or log any credential value.
    if (!e.key.startsWith('AGENT_OFFICE_') && _credential.hasMatch(e.key)) continue;
    env[e.key] = e.value;
  }
  final config = p.join(f.root, 'config');
  env.addAll({
    'PATH': '${f.bin}:${Platform.environment['PATH'] ?? ''}',
    'HOME': p.join(f.root, 'home'),
    'USERPROFILE': p.join(f.root, 'home'),
    'XDG_CONFIG_HOME': config,
    'XDG_DATA_HOME': p.join(f.root, 'xdg-data'),
    'XDG_STATE_HOME': p.join(f.root, 'xdg-state'),
    'XDG_CACHE_HOME': p.join(f.root, 'xdg-cache'),
    'CLAUDE_CONFIG_DIR': p.join(config, 'claude'),
    'OPENCODE_CONFIG_DIR': p.join(config, 'opencode'),
    'CODEX_HOME': p.join(config, 'codex'),
    ...extra,
  });
  return env;
}

WorkerEvents events(List<WorkerInfo> updates) =>
    WorkerEvents(update: updates.add, remove: (_) {}, data: (_, _, _) {}, screen: (_, _) {}, toast: (_, _) {});

Ledger ledger(String data) => Ledger(data, LedgerOptions(pauseHiring: false), (_) {}, (_, _) {});

const _hook = HookEnv(url: 'http://127.0.0.1:1', token: '');

WorkerManager manager(
  Fixture f,
  String cmd,
  List<WorkerInfo> updates,
  Map<String, String> env, {
  List<String> args = const ['--from-test'],
  Ledger? book,
  PromptSource? prompts,
  RunAs? runAs,
}) => WorkerManager(
  f.root,
  f.data,
  cmd,
  args,
  _hook,
  events(updates),
  book ?? ledger(f.data),
  env: env,
  prompts: prompts,
  runAs: runAs,
);

Future<T> waitFor<T>(T Function() read, bool Function(T value) predicate, {int timeout = 10000}) async {
  final end = DateTime.now().add(Duration(milliseconds: timeout));
  var value = read();
  while (!predicate(value) && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    value = read();
  }
  expect(predicate(value), isTrue, reason: 'timed out waiting for fake agent state');
  return value;
}

bool hasPrompt(Invocation invocation, String prompt) =>
    invocation.args.contains(prompt) || (invocation.stdin?.contains(prompt) ?? false);

WorkerInfo spawned(({WorkerInfo? worker, String? error}) r) {
  expect(r.error, isNull);
  expect(r.worker, isNotNull);
  return r.worker!;
}

String? usageJson(Usage? u) => u == null ? null : jsonEncode(u.toJson());

void main() {
  test(
    'Claude workers use the configured executable, pass prompts and resume ids, and stay hook-operational',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '180', 'FAKE_AGENT_LOG': f.log});
      final workers = manager(f, f.claude, [], env);
      addTearDown(workers.shutdown);
      final worker = spawned(workers.spawn('desk-1', 'test', 'initial Claude prompt'));
      bool claudeWorker(Invocation r) => r.kind == 'claude' && r.args.contains('--settings');
      final first = await waitFor(f.read, (records) => records.any(claudeWorker));
      final firstWorker = first.firstWhere(claudeWorker);
      expect(firstWorker.args, contains('--from-test'));
      expect(hasPrompt(firstWorker, 'initial Claude prompt'), isTrue);
      expect(firstWorker.workerId, worker.id);
      expect(firstWorker.hookToken, isNotEmpty);

      expect(
        workers.handleHook(worker.id, firstWorker.hookToken!, 'SessionStart', {'session_id': 'claude-session-1'}),
        isTrue,
      );
      expect(workers.get(worker.id)?.status, WorkerStatus.idle);
      await waitFor(() => workers.get(worker.id)?.status, (status) => status == WorkerStatus.exited);
      expect(workers.resume(worker.id), isNull);
      final resumed = await waitFor(f.read, (records) => records.where(claudeWorker).length >= 2);
      final secondWorker = resumed.where(claudeWorker).elementAt(1);
      expect(secondWorker.args, contains('--resume'));
      expect(secondWorker.args, contains('claude-session-1'));
      expect(secondWorker.args, isNot(contains('initial Claude prompt')));

      // The Claude hook remains accepted after a resume and updates the activity state.
      expect(
        workers.handleHook(worker.id, firstWorker.hookToken!, 'UserPromptSubmit', {'prompt': 'follow-up'}),
        isTrue,
      );
      expect(workers.get(worker.id)?.activity, 'follow-up');

      // Selecting the alternate provider uses its binary with a clean argument set.
      final alternate = spawned(
        workers.spawn('desk-4', 'test', 'alternate provider prompt', false, WorkerKind.agent, AgentProvider.opencode),
      );
      final alternateRecords = await waitFor(f.read, (records) => records.any((r) => r.kind == 'opencode'));
      final alternateInvocation = alternateRecords.firstWhere((r) => r.kind == 'opencode');
      expect(alternateInvocation.args, isNot(contains('--from-test')));
      expect(alternateInvocation.args, isNot(contains('--settings')));
      expect(hasPrompt(alternateInvocation, 'alternate provider prompt'), isTrue);
      await workers.kill(alternate.id);
    },
  );

  test(
    'OpenCode workers use OpenCode-only hooks/config, never invoke Claude naming, and restore provider sessions',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '900', 'FAKE_AGENT_LOG': f.log});
      final workers = manager(f, f.opencode, [], env);
      addTearDown(workers.shutdown);
      expect(workers.defaultProvider, AgentProvider.opencode);
      final worker = spawned(workers.spawn('desk-2', 'test', 'initial OpenCode prompt'));

      final first = await waitFor(f.read, (records) => records.any((r) => r.kind == 'opencode'));
      final firstWorker = first.firstWhere((r) => r.kind == 'opencode');
      final token = firstWorker.hookToken!;
      expect(firstWorker.args, contains('--from-test'));
      expect(hasPrompt(firstWorker, 'initial OpenCode prompt'), isTrue);
      final initialTask = workers.get(worker.id)?.task;
      expect(initialTask, isNotNull);
      expect(firstWorker.args, isNot(contains('--settings')));
      expect(firstWorker.workerId, worker.id);
      expect(token, isNotEmpty);
      expect(firstWorker.opencodeConfig, contains('agent-office-opencode'));
      // The office's MCP server, which OpenCode runs with the worker's environment.
      final mcp = ((jsonDecode(firstWorker.opencodeConfig!) as Map)['mcp'] as Map?)?['agent-office'] as Map?;
      expect((mcp?['command'] as List?)?.sublist((mcp!['command'] as List).length - 2), ['workers', 'mcp']);
      expect(first.where((r) => r.kind == 'claude'), isEmpty, reason: 'OpenCode must not launch the Claude task namer');

      final transcript = p.join(f.root, 'must-not-be-read.jsonl');
      File(transcript).writeAsStringSync(
        '${jsonEncode({
          'type': 'assistant',
          'message': {
            'id': 'x',
            'model': 'opus',
            'usage': {'input_tokens': 9000, 'output_tokens': 1000},
          },
        })}\n',
      );
      bool hook(String t, Map<String, Object?> payload) => workers.handleOpenCodeHook(worker.id, t, payload);
      expect(hook('wrong-token', {'type': 'session', 'sessionId': 'oc-1', 'status': 'starting'}), isFalse);
      expect(
        hook(token, {'type': 'session', 'sessionId': 'oc-1', 'status': 'starting', 'transcript_path': transcript}),
        isTrue,
      );
      expect(workers.get(worker.id)?.status, WorkerStatus.idle);
      expect(
        hook(token, {'type': 'prompt', 'sessionId': 'oc-1', 'status': 'working', 'prompt': 'do the thing'}),
        isTrue,
      );
      expect(workers.get(worker.id)?.status, WorkerStatus.working);
      expect(
        hook(token, {'type': 'permission', 'sessionId': 'oc-1', 'status': 'needs_input', 'detail': 'write file'}),
        isTrue,
      );
      expect(workers.get(worker.id)?.status, WorkerStatus.needsInput);
      expect(
        hook(token, {'type': 'error', 'sessionId': 'oc-1', 'status': 'done', 'detail': 'provider unavailable'}),
        isTrue,
      );
      expect(workers.get(worker.id)?.status, WorkerStatus.needsInput);
      expect(workers.get(worker.id)?.activity, 'provider unavailable');
      expect(
        hook(token, {'type': 'prompt', 'sessionId': 'oc-1', 'status': 'working', 'prompt': 'retry the thing'}),
        isTrue,
      );
      expect(workers.get(worker.id)?.status, WorkerStatus.working);
      // A fresh root session is accepted at the start of a new OpenCode turn.
      expect(hook(token, {'type': 'session', 'sessionId': 'oc-child', 'status': 'starting'}), isTrue);
      expect(workers.get(worker.id)?.sessionId, 'oc-child');
      expect(workers.get(worker.id)?.task, isNull, reason: 'a new OpenCode session starts a new task card');
      expect(
        hook(token, {
          'type': 'prompt',
          'sessionId': 'oc-child',
          'status': 'working',
          'prompt': 'replace the previous task with this one',
        }),
        isTrue,
      );
      expect(jsonEncode(workers.get(worker.id)?.task?.toJson()), isNot(jsonEncode(initialTask?.toJson())));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(workers.get(worker.id)?.usage, isNull, reason: 'OpenCode must not run Claude transcript usage parsing');
      expect(hook(token, {'type': 'session', 'sessionId': 'oc-child', 'status': 'done'}), isTrue);

      await waitFor(() => workers.get(worker.id)?.status, (status) => status == WorkerStatus.exited);
      expect(workers.resume(worker.id), isNull);
      final resumed = await waitFor(f.read, (records) => records.where((r) => r.kind == 'opencode').length >= 2);
      final secondWorker = resumed.where((r) => r.kind == 'opencode').elementAt(1);
      expect(secondWorker.args.contains('--session') || secondWorker.args.contains('-s'), isTrue);
      expect(secondWorker.args, contains('oc-child'));
      expect(secondWorker.args, isNot(contains('initial OpenCode prompt')));
      expect(secondWorker.hookToken, isNotEmpty);
      expect(secondWorker.hookToken, isNot(token), reason: 'resuming OpenCode rotates its hook token');
      expect(
        hook(token, {'type': 'prompt', 'sessionId': 'oc-child', 'status': 'working', 'prompt': 'stale token'}),
        isFalse,
      );
      expect(
        hook(secondWorker.hookToken!, {
          'type': 'prompt',
          'sessionId': 'oc-child',
          'status': 'working',
          'prompt': 'fresh token',
        }),
        isTrue,
      );

      await workers.shutdown();
      final restored = manager(f, f.opencode, [], env);
      addTearDown(restored.shutdown);
      // Wakes the workers from before the restart (see WorkerManager.start).
      await restored.start();
      expect(restored.get(worker.id)?.provider, AgentProvider.opencode);
      expect(restored.get(worker.id)?.prompt, 'initial OpenCode prompt');
      expect(restored.get(worker.id)?.sessionId, 'oc-child');
      await waitFor(f.read, (records) => records.where((r) => r.kind == 'opencode').length >= 3);
      final restoredInvocation = f.read().where((r) => r.kind == 'opencode').elementAt(2);
      expect(restoredInvocation.args.contains('--session') || restoredInvocation.args.contains('-s'), isTrue);
      expect(restoredInvocation.args, contains('oc-child'));
      expect(restored.get(worker.id)?.status, isIn([WorkerStatus.idle, WorkerStatus.exited, WorkerStatus.done]));
      expect(
        f.read().where((r) => r.kind == 'claude'),
        isEmpty,
        reason: 'OpenCode must never invoke Claude task naming',
      );
    },
  );

  test('OpenCode model overrides configured model flags on first launch and is omitted on resume', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '180', 'FAKE_AGENT_LOG': f.log});
    final workers = manager(
      f,
      f.opencode,
      [],
      env,
      args: ['--model', 'old/model', '--keep', 'yes', '-m', 'older/model'],
    );
    addTearDown(workers.shutdown);
    final worker = spawned(
      workers.spawn(
        'desk-1',
        'test',
        'modelled prompt',
        false,
        WorkerKind.agent,
        AgentProvider.opencode,
        'openai/gpt-5/nested',
      ),
    );
    final first = await waitFor(f.read, (records) => records.any((r) => r.kind == 'opencode'));
    final firstInvocation = first.firstWhere((r) => r.kind == 'opencode');
    expect(firstInvocation.args, ['--keep', 'yes', '--model', 'openai/gpt-5/nested', '--prompt', 'modelled prompt']);
    expect(workers.get(worker.id)?.model, 'openai/gpt-5/nested');

    expect(
      workers.handleOpenCodeHook(worker.id, firstInvocation.hookToken!, {
        'type': 'session',
        'sessionId': 'oc-model',
        'status': 'starting',
      }),
      isTrue,
    );
    await waitFor(() => workers.get(worker.id)?.status, (status) => status == WorkerStatus.exited);
    expect(workers.resume(worker.id), isNull);
    final all = await waitFor(f.read, (records) => records.where((r) => r.kind == 'opencode').length >= 2);
    final resumed = all.where((r) => r.kind == 'opencode').elementAt(1);
    expect(resumed.args, contains('--session'));
    expect(resumed.args, contains('oc-model'));
    expect(resumed.args, isNot(contains('--model')));
    expect(resumed.args, isNot(contains('openai/gpt-5/nested')));
  });

  test(
    'OpenCode keeps configured model flags when no explicit model is selected, then strips them on resume',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '180', 'FAKE_AGENT_LOG': f.log});
      final workers = manager(f, f.opencode, [], env, args: ['--model', 'configured/model', '--keep', 'yes']);
      addTearDown(workers.shutdown);
      final worker = spawned(workers.spawn('desk-1', 'test', 'configured prompt'));
      final first = await waitFor(f.read, (records) => records.any((r) => r.kind == 'opencode'));
      final firstInvocation = first.firstWhere((r) => r.kind == 'opencode');
      expect(firstInvocation.args, contains('--model'));
      expect(firstInvocation.args, contains('configured/model'));
      expect(
        workers.handleOpenCodeHook(worker.id, firstInvocation.hookToken!, {
          'type': 'session',
          'sessionId': 'oc-configured',
          'status': 'starting',
        }),
        isTrue,
      );
      await waitFor(() => workers.get(worker.id)?.status, (status) => status == WorkerStatus.exited);
      expect(workers.resume(worker.id), isNull);
      final all = await waitFor(f.read, (records) => records.where((r) => r.kind == 'opencode').length >= 2);
      final resumed = all.where((r) => r.kind == 'opencode').elementAt(1);
      expect(resumed.args, contains('--session'));
      expect(resumed.args, isNot(contains('--model')));
      expect(resumed.args, isNot(contains('configured/model')));
      expect(resumed.args, contains('--keep'));
    },
  );

  test('workers reject models their provider does not take, and malformed model ids', () async {
    final f = Fixture();
    addTearDown(f.close);
    final workers = manager(f, f.claude, [], {...Platform.environment, 'FAKE_AGENT_LOG': f.log});
    addTearDown(workers.shutdown);
    String? error(String desk, WorkerKind kind, AgentProvider? provider, String model) =>
        workers.spawn(desk, 'test', 'bad', false, kind, provider, model).error;
    expect(
      error('desk-1', WorkerKind.agent, AgentProvider.claude, 'openai/gpt-5'),
      matches(RegExp('model', caseSensitive: false)),
    );
    expect(
      error('desk-2', WorkerKind.agent, AgentProvider.opencode, 'gpt-5'),
      matches(RegExp('model|format|provider', caseSensitive: false)),
    );
    expect(
      error('desk-3', WorkerKind.agent, AgentProvider.opencode, 'openai/gpt 5'),
      matches(RegExp('model|format|whitespace', caseSensitive: false)),
    );
    expect(
      error('desk-4', WorkerKind.shell, null, 'openai/gpt-5'),
      matches(RegExp('shell|model', caseSensitive: false)),
    );
  });

  test('provider and hook boundaries reject invalid combinations', () async {
    final f = Fixture();
    addTearDown(f.close);
    final workers = manager(f, f.claude, [], {...Platform.environment, 'FAKE_AGENT_LOG': f.log});
    addTearDown(workers.shutdown);
    final invalidProvider = workers.spawn('desk-3', 'test', null, false, WorkerKind.agent, AgentProvider.custom);
    expect(invalidProvider.worker, isNull);
    expect(invalidProvider.error, matches(RegExp('configured|provider|executable', caseSensitive: false)));
    final claude = spawned(workers.spawn('desk-3', 'test', 'claude task'));
    expect(
      workers.handleOpenCodeHook(claude.id, 'any-token', {
        'type': 'session',
        'sessionId': 'wrong',
        'status': 'starting',
      }),
      isFalse,
    );

    // A custom wrapper still speaks the Claude hook protocol; only OpenCode is
    // excluded from that path.
    final customFixture = Fixture();
    addTearDown(customFixture.close);
    final customWorkers = manager(customFixture, customFixture.custom, [], {
      ...Platform.environment,
      'FAKE_AGENT_LOG': customFixture.log,
    });
    addTearDown(customWorkers.shutdown);
    expect(customWorkers.defaultProvider, AgentProvider.custom);
    final custom = spawned(customWorkers.spawn('desk-4', 'test', 'custom wrapper task'));
    final invocation = await waitFor(customFixture.read, (records) => records.any((r) => r.kind == 'custom-agent'));
    final token = invocation.firstWhere((r) => r.kind == 'custom-agent').hookToken;
    expect(token, isNotEmpty);
    expect(customWorkers.handleHook(custom.id, token!, 'SessionStart', {'session_id': 'custom-session'}), isTrue);
  });

  test(
    'OpenCode usage snapshots replace totals, persist across restart, and never change status or Claude budget',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
      final book = ledger(f.data);
      final workers = manager(f, f.opencode, [], env, args: [], book: book);
      addTearDown(workers.shutdown);
      final worker = spawned(workers.spawn('desk-1', 'test'));
      final invocations = await waitFor(f.read, (x) => x.any((r) => r.kind == 'opencode'));
      final token = invocations.firstWhere((r) => r.kind == 'opencode').hookToken!;
      workers.handleOpenCodeHook(worker.id, token, {
        'type': 'session',
        'sessionId': 'usage-root',
        'status': 'starting',
      });
      workers.handleOpenCodeHook(worker.id, token, {
        'type': 'permission',
        'sessionId': 'usage-root',
        'status': 'needs_input',
      });
      final usage = <String, Object>{
        'input': 20,
        'output': 8,
        'reasoning': 4,
        'cacheRead': 6,
        'cacheWrite': 2,
        'cost': 0.003,
        'calls': 1,
        'costKnown': true,
      };
      final report = {'type': 'usage', 'sessionId': 'usage-root', 'usage': usage};
      expect(workers.handleOpenCodeHook(worker.id, token, report), isTrue);
      expect(workers.handleOpenCodeHook(worker.id, token, report), isTrue);
      expect(workers.get(worker.id)?.usage?.toJson(), equals(usage));
      expect(workers.get(worker.id)?.status, WorkerStatus.needsInput);
      expect(book.state().total.calls, 0);
      expect(book.state().total.cost, 0);
      for (final bad in [
        {...usage, 'input': -1},
        {...usage, 'cost': double.infinity},
        {...usage, 'calls': '1'},
      ]) {
        expect(workers.handleOpenCodeHook(worker.id, token, {...report, 'usage': bad}), isFalse);
      }
      expect(workers.handleOpenCodeHook(worker.id, 'wrong', report), isFalse);
      expect(workers.handleOpenCodeHook(worker.id, token, {...report, 'sessionId': 'unrelated'}), isFalse);
      await workers.shutdown();
      final restored = manager(f, f.opencode, [], env, args: []);
      addTearDown(restored.shutdown);
      // Wakes the workers from before the restart (see WorkerManager.start).
      await restored.start();
      expect(restored.get(worker.id)?.usage?.toJson(), equals(usage));
      bool fresh(Invocation r) => r.kind == 'opencode' && r.stdin == null;
      final calls = await waitFor(f.read, (x) => x.where(fresh).length >= 2);
      final nextToken = calls.where(fresh).last.hookToken!;
      restored.handleOpenCodeHook(worker.id, nextToken, {
        'type': 'session',
        'sessionId': 'next-root',
        'status': 'starting',
      });
      expect(restored.get(worker.id)?.usage, isNull);
    },
  );

  test(
    'Codex workers preserve native approvals, follow authenticated root hooks, and resume their provider session',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
      final book = ledger(f.data);
      final workers = manager(f, f.claude, [], env, args: ['--claude-only'], book: book);
      addTearDown(workers.shutdown);
      final worker = spawned(
        workers.spawn('desk-1', 'test', '- fix the login', false, WorkerKind.agent, AgentProvider.codex),
      );
      final calls = await waitFor(f.read, (x) => x.any((r) => r.kind == 'codex'));
      final first = calls.firstWhere((r) => r.kind == 'codex');
      final token = first.hookToken!;
      expect(workers.get(worker.id)?.status, WorkerStatus.starting);
      expect(first.args, contains('--no-alt-screen'));
      // The office's MCP server, with the office's variables passed on to it, which Codex doesn't do unasked.
      expect(
        first.args,
        contains('mcp_servers.agent-office.args=${jsonEncode([...officeCommand().sublist(1), 'workers', 'mcp'])}'),
      );
      expect(
        first.args,
        contains(
          'mcp_servers.agent-office.env_vars=["AGENT_OFFICE_HOOK_URL","AGENT_OFFICE_WORKER_ID","AGENT_OFFICE_HOOK_TOKEN"]',
        ),
      );
      expect(first.args.sublist(first.args.length - 2), ['--', '- fix the login']);
      expect(first.args.any(RegExp(r'bypass|--yolo|--claude-only|--settings').hasMatch), isFalse);
      expect(first.args.where((a) => a.startsWith('hooks.')).length, 7);
      expect(calls.any((r) => r.kind == 'claude'), isFalse);
      bool hook(String event, [Map<String, Object?> extra = const {}]) =>
          workers.handleCodexHook(worker.id, token, event, {'session_id': 'codex-root', ...extra});
      WorkerStatus? status() => workers.get(worker.id)?.status;
      expect(workers.handleCodexHook(worker.id, 'wrong', 'SessionStart', {'session_id': 'codex-root'}), isFalse);
      expect(hook('SessionStart', {'source': 'startup'}), isTrue);
      expect(status(), WorkerStatus.idle);
      expect(hook('UserPromptSubmit', {'prompt': 'Implement the actual task'}), isTrue);
      expect(status(), WorkerStatus.working);
      expect(hook('PreToolUse', {'tool_name': 'exec_command', 'tool_use_id': 'call-permission'}), isTrue);
      expect(hook('PreToolUse', {'tool_name': 'read_file', 'tool_use_id': 'call-other'}), isTrue);
      expect(hook('PermissionRequest', {'tool_name': 'exec_command'}), isTrue);
      expect(hook('PostToolUse', {'tool_name': 'read_file', 'tool_use_id': 'call-other'}), isTrue);
      expect(status(), WorkerStatus.needsInput);
      expect(hook('Stop', {'agent_id': 'child'}), isFalse);
      expect(status(), WorkerStatus.needsInput);
      expect(hook('PostToolUse', {'tool_name': 'exec_command', 'tool_use_id': 'call-permission'}), isTrue);
      expect(status(), WorkerStatus.working);
      expect(hook('Stop'), isTrue);
      expect(status(), WorkerStatus.done);
      expect(workers.handleHook(worker.id, token, 'Stop', {'session_id': 'claude'}), isFalse);
      expect(
        workers.handleOpenCodeHook(worker.id, token, {'type': 'session', 'sessionId': 'oc', 'status': 'starting'}),
        isFalse,
      );
      expect(workers.get(worker.id)?.sessionId, 'codex-root');
      expect(workers.get(worker.id)?.usage, isNull);
      expect(book.state().total.calls, 0);
      await workers.shutdown();
      final restored = manager(f, f.claude, [], env, args: []);
      addTearDown(restored.shutdown);
      // Wakes the workers from before the restart (see WorkerManager.start).
      await restored.start();
      bool fresh(Invocation r) => r.kind == 'codex' && r.stdin == null;
      final nextCalls = await waitFor(f.read, (x) => x.where(fresh).length >= 2);
      final next = nextCalls.where(fresh).last;
      expect(next.args.sublist(next.args.length - 2), ['resume', 'codex-root']);
      expect(next.hookToken, isNot(token));
      expect(restored.get(worker.id)?.provider, AgentProvider.codex);
      expect(restored.handleCodexHook(worker.id, token, 'Stop', {'session_id': 'codex-root'}), isFalse);
      expect(
        restored.handleCodexHook(worker.id, next.hookToken!, 'SessionStart', {
          'session_id': 'codex-root',
          'source': 'resume',
        }),
        isTrue,
      );
      expect(restored.get(worker.id)?.status, WorkerStatus.idle);
    },
  );

  test('Codex token snapshots survive restart, preserve permissions, and stay outside Claude spend', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'CODEX_HOME': 'relative-codex-home', 'FAKE_AGENT_LOG': f.log});
    final book = ledger(f.data);
    final workers = manager(f, f.codex, [], env, args: [], book: book);
    addTearDown(workers.shutdown);
    final worker = spawned(workers.spawn('desk-1', 'test'));
    final calls = await waitFor(f.read, (x) => x.any((r) => r.kind == 'codex'));
    final token = calls.firstWhere((r) => r.kind == 'codex').hookToken!;
    final dir = p.join(f.root, 'relative-codex-home', 'sessions', '2026', '09', '26');
    Directory(dir).createSync(recursive: true);
    final transcript = p.join(dir, 'rollout-fixture-metrics-root.jsonl');
    String metric(int input) =>
        '${jsonEncode({
          'type': 'event_msg',
          'payload': {
            'type': 'token_count',
            'info': {
              'total_token_usage': {'input_tokens': input, 'cached_input_tokens': 20, 'output_tokens': 30, 'reasoning_output_tokens': 10, 'total_tokens': input + 30},
            },
          },
        })}\n';
    File(transcript).writeAsStringSync(
      '${jsonEncode({
        'type': 'session_meta',
        'payload': {'id': 'metrics-root'},
      })}\n${metric(120)}',
    );
    Usage? usage() => workers.get(worker.id)?.usage;
    expect(
      workers.handleCodexHook(worker.id, 'wrong', 'SessionStart', {
        'session_id': 'metrics-root',
        'transcript_path': transcript,
      }),
      isFalse,
    );
    expect(usage(), isNull);
    workers.handleCodexHook(worker.id, token, 'SessionStart', {
      'session_id': 'metrics-root',
      'transcript_path': transcript,
    });
    workers.handleCodexHook(worker.id, token, 'PermissionRequest', {'session_id': 'metrics-root', 'tool_name': 'Bash'});
    await waitFor(usage, (u) => u?.input == 100);
    expect(workers.get(worker.id)?.status, WorkerStatus.needsInput);
    expect(usage()?.output, 20);
    expect(usage()?.reasoning, 10);
    expect(usage()?.cacheRead, 20);
    expect(usage()?.costKnown, false);
    expect(usage()?.callsKnown, false);
    expect(workers.get(worker.id)!.toJson().containsKey('codexTranscript'), isFalse);
    File(transcript).writeAsStringSync(metric(120) + metric(240), mode: FileMode.append);
    workers.handleCodexHook(worker.id, token, 'Stop', {'session_id': 'metrics-root'});
    await waitFor(usage, (u) => u?.input == 220);
    expect(book.state().total.calls, 0);
    expect(book.state().total.cost, 0);
    final last = usageJson(usage());
    await workers.shutdown();
    final restored = manager(f, f.codex, [], env, args: []);
    addTearDown(restored.shutdown);
    // Wakes the workers from before the restart (see WorkerManager.start).
    await restored.start();
    expect(usageJson(restored.get(worker.id)?.usage), last);
    bool fresh(Invocation r) => r.kind == 'codex' && r.stdin == null;
    final nextCalls = await waitFor(f.read, (x) => x.where(fresh).length >= 2);
    final next = nextCalls.where(fresh).last;
    File(transcript).writeAsStringSync(metric(300), mode: FileMode.append);
    restored.handleCodexHook(worker.id, next.hookToken!, 'SessionStart', {
      'session_id': 'metrics-root',
      'transcript_path': transcript,
    });
    await waitFor(() => restored.get(worker.id)?.usage, (u) => u?.input == 280);
    restored.handleCodexHook(worker.id, next.hookToken!, 'SessionStart', {'session_id': 'new-root', 'source': 'clear'});
    expect(restored.get(worker.id)?.usage, isNull);
  });

  // --- #79 #88: a Claude model and effort per worker -------------------------------------------

  test('workers reject reasoning effort for a provider that takes none', () async {
    final f = Fixture();
    addTearDown(f.close);
    final workers = manager(f, f.claude, [], {...Platform.environment, 'FAKE_AGENT_LOG': f.log});
    addTearDown(workers.shutdown);
    expect(
      workers
          .spawn('desk-2', 'test', 'bad', false, WorkerKind.agent, AgentProvider.cursor, null, AgentEffort.high)
          .error,
      matches(RegExp('effort', caseSensitive: false)),
    );
    expect(
      workers.spawn('desk-3', 'test', 'bad', false, WorkerKind.shell, null, null, AgentEffort.high).error,
      matches(RegExp('shell|effort', caseSensitive: false)),
    );
  });

  test('an explicit Claude model/effort overrides --agent-args and persists across resume', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '180', 'FAKE_AGENT_LOG': f.log});
    final workers = manager(f, f.claude, [], env, args: ['--model', 'opus']);
    addTearDown(workers.shutdown);
    final worker = spawned(
      workers.spawn(
        'desk-1',
        'test',
        'haiku task',
        false,
        WorkerKind.agent,
        AgentProvider.claude,
        'haiku',
        AgentEffort.high,
      ),
    );
    expect(workers.get(worker.id)?.model, 'haiku');
    expect(workers.get(worker.id)?.effort, AgentEffort.high);
    final first = (await waitFor(f.read, (records) => records.any(_claudeLaunch))).firstWhere(_claudeLaunch);
    // The per-worker choice is appended after --agent-args, so it wins even though "opus" also appears.
    expect(first.args.sublist(first.args.indexOf('--model')), [
      '--model',
      'opus',
      '--model',
      'haiku',
      '--effort',
      'high',
      '--',
      'haiku task',
    ]);
    expect(workers.handleHook(worker.id, first.hookToken!, 'SessionStart', {'session_id': 'claude-model-1'}), isTrue);
    await waitFor(() => workers.get(worker.id)?.status, (s) => s == WorkerStatus.exited);
    expect(workers.resume(worker.id), isNull);
    final second = (await waitFor(f.read, (r) => r.where(_claudeLaunch).length >= 2)).where(_claudeLaunch).elementAt(1);
    expect(second.args, containsAll(['--model', 'haiku', '--effort', 'high', '--resume']));

    await workers.shutdown();
    final restored = manager(f, f.claude, [], env, args: ['--model', 'opus']);
    addTearDown(restored.shutdown);
    await restored.start();
    expect(restored.get(worker.id)?.model, 'haiku');
    expect(restored.get(worker.id)?.effort, AgentEffort.high);
  });

  test("a worker hired by an account runs on that account's own sign-ins, after a restart too", () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log, 'ANTHROPIC_API_KEY': 'sk-ant-api03-office'});
    final signins = SignIns(
      f.data,
      f.claude,
      null,
      () => Map.of(env),
      (_) => false,
      (_) {},
      run: (cmd, args, env, [input]) async => (code: 1, out: '', last: ''),
    );
    final workers = manager(f, f.claude, [], env, runAs: signins);
    addTearDown(workers.shutdown);
    // Not signed in to Claude yet: the hire is refused, and says where to sign in.
    final refused = workers.spawn(
      'desk-1',
      'Ada',
      'task',
      false,
      WorkerKind.agent,
      AgentProvider.claude,
      null,
      null,
      null,
      const [],
      'acct0ada',
    );
    expect(refused.error, contains('Sign in to Claude first'));
    expect(await signins.token('acct0ada', SignInKind.claude, 'sk-ant-oat01-${'x' * 40}'), isNull);
    final worker = spawned(
      workers.spawn(
        'desk-1',
        'Ada',
        'task',
        false,
        WorkerKind.agent,
        AgentProvider.claude,
        null,
        null,
        null,
        const [],
        'acct0ada',
      ),
    );
    expect(workers.ownerOf(worker.id), 'acct0ada');
    final launch = (await waitFor(f.read, (r) => r.any(_claudeLaunch))).firstWhere(_claudeLaunch);
    expect(launch.env['claudeConfig'], p.join(f.data, 'homes', 'acct0ada', 'claude'));
    expect(
      launch.env.containsKey('apiKey'),
      isFalse,
      reason: "the office's own key never reaches someone else's worker",
    );
    // Hired without an account, a worker runs as the office.
    final office = spawned(workers.spawn('desk-2', 'Guest', 'task', false, WorkerKind.agent, AgentProvider.claude));
    final officeLaunch = (await waitFor(
      f.read,
      (r) => r.where(_claudeLaunch).length >= 2,
    )).where(_claudeLaunch).firstWhere((x) => x.workerId == office.id);
    expect(officeLaunch.env['apiKey'], 'sk-ant-api03-office');
    await workers.shutdown();
    final restored = manager(f, f.claude, [], env, runAs: signins);
    addTearDown(restored.shutdown);
    await restored.start();
    expect(restored.ownerOf(worker.id), 'acct0ada');
    expect(restored.ownerOf(office.id), isNull);
  });

  test('a worker hired on Fable launches with --model fable and keeps it across a restart', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
    final workers = manager(f, f.claude, [], env, args: ['--model', 'opus']);
    addTearDown(workers.shutdown);
    final worker = spawned(
      workers.spawn('desk-1', 'test', 'fable task', false, WorkerKind.agent, AgentProvider.claude, 'fable'),
    );
    final launch = (await waitFor(f.read, (r) => r.any(_claudeLaunch))).firstWhere(_claudeLaunch);
    expect(launch.args.sublist(launch.args.indexOf('--model')), [
      '--model',
      'opus',
      '--model',
      'fable',
      '--',
      'fable task',
    ]);
    await workers.shutdown();
    final restored = manager(f, f.claude, [], env, args: ['--model', 'opus']);
    addTearDown(restored.shutdown);
    await restored.start();
    expect(restored.get(worker.id)?.model, 'fable');
  });

  // --- #76 #86 #137: board agents ----------------------------------------------------------------

  test(
    'a board agent is hired with its brief on the first prompt, then prompted, woken and asked to prove who it is',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '600', 'FAKE_AGENT_LOG': f.log});
      final workers = manager(f, f.claude, [], env);
      addTearDown(workers.shutdown);
      // Each start of the agent, not what it reads from its terminal afterwards.
      List<Invocation> launches() => f.read().where((r) => _claudeLaunch(r) && r.stdin == null).toList();

      expect(
        workers.station('desk-1', 'test', 'file an issue').error,
        matches(RegExp('no agent', caseSensitive: false)),
      );
      expect(workers.station('station-issues', 'test', '   ').error, matches(RegExp('empty', caseSensitive: false)));
      expect(
        workers.spawn('station-issues', 'test', null, false, WorkerKind.shell).error,
        matches(RegExp('shell', caseSensitive: false)),
      );

      // Nobody there yet: it's hired, told what it's for, with the request after that.
      final hired = workers.station('station-issues', 'Ada', 'File an issue about the dog');
      expect(hired.error, isNull);
      expect(hired.hired, isTrue);
      expect(hired.info!.name, 'Issues agent');
      expect(hired.info!.deskId, 'station-issues');
      expect(hired.info!.activity, 'File an issue about the dog');
      final first = (await waitFor(launches, (l) => l.length == 1)).first;
      final initial = first.args.last;
      expect(initial, contains('Issues agent'));
      expect(initial, contains('agent-office queue add'));
      // Only the queue agent loses its file-editing tools.
      expect(first.args, isNot(contains('--disallowedTools')));
      expect(initial, endsWith('File an issue about the dog'));
      final id = hired.info!.id;

      // The same agent takes the next request in its session.
      final again = workers.station('station-issues', 'Grace', 'Label it as a bug');
      expect([again.hired, again.info?.id], [false, id]);
      await waitFor(f.read, (records) => records.any((r) => r.stdin?.contains('Label it as a bug') ?? false));

      // Waiting on an answer, a prompt would answer the question, so it's refused.
      expect(workers.handleHook(id, first.hookToken!, 'SessionStart', {'session_id': 'issues-session'}), isTrue);
      expect(
        workers.handleHook(id, first.hookToken!, 'PermissionRequest', {
          'tool_name': 'Bash',
          'tool_input': {'command': 'gh issue create'},
        }),
        isTrue,
      );
      expect(workers.get(id)?.status, WorkerStatus.needsInput);
      expect(
        workers.station('station-issues', 'Ada', 'hello?').error,
        matches(RegExp('waiting on an answer', caseSensitive: false)),
      );

      // Its own token proves who it is; anyone else's doesn't.
      expect(workers.authenticate(id, first.hookToken!)?.id, id);
      expect(workers.authenticate(id, 'not-its-token'), isNull);
      expect(workers.authenticate(id, ''), isNull);

      // Asleep, a request wakes it up carrying on its session, without the brief again.
      await waitFor(() => workers.get(id)?.status, (s) => s == WorkerStatus.exited);
      expect(workers.authenticate(id, first.hookToken!), isNull);
      final woken = workers.station('station-issues', 'Ada', 'Close the duplicates');
      expect([woken.hired, woken.info?.id], [false, id]);
      final second = (await waitFor(launches, (l) => l.length == 2))[1];
      expect(second.args, containsAll(['--resume', 'issues-session']));
      expect(second.args.last, 'Close the duplicates');
    },
  );

  test(
    'a worker nobody picked a model for starts on the office default, and a board agent is told its rewritten brief',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
      final workers = manager(
        f,
        f.claude,
        [],
        env,
        prompts: _Prompts(
          (id) => id == 'station.issues' ? 'You triage issues. The request:' : prompts[id]!.text,
          const AgentChoice(provider: AgentProvider.claude, model: 'sonnet', effort: AgentEffort.low),
        ),
      );
      addTearDown(workers.shutdown);
      List<Invocation> launches(String id) =>
          f.read().where((r) => _claudeLaunch(r) && r.stdin == null && r.workerId == id).toList();
      String? flag(List<String> args, String name) => args.contains(name) ? args[args.indexOf(name) + 1] : null;

      final hired = workers.station('station-issues', 'Ada', 'File one about the dog');
      expect(hired.error, isNull);
      expect(
        [hired.info!.provider, hired.info!.model, hired.info!.effort],
        [AgentProvider.claude, 'sonnet', AgentEffort.low],
      );
      final first = (await waitFor(() => launches(hired.info!.id), (l) => l.length == 1)).first;
      expect(first.args.last, 'You triage issues. The request:\n\nFile one about the dog');
      expect([flag(first.args, '--model'), flag(first.args, '--effort')], ['sonnet', 'low']);

      // Picked at the desk, the pick wins, down to "the provider's own model".
      final desk = spawned(workers.spawn('desk-1', 'Ada', 'Fix it', false, WorkerKind.agent, AgentProvider.claude));
      expect([desk.provider, desk.model, desk.effort], [AgentProvider.claude, null, null]);
      final own = (await waitFor(() => launches(desk.id), (l) => l.length == 1)).first;
      expect(own.args, isNot(contains('--model')));
    },
  );

  test(
    'the queue agent is launched without file-editing tools, and board agents get agent-office on their PATH',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '600', 'FAKE_AGENT_LOG': f.log});
      final workers = manager(f, f.claude, [], env);
      addTearDown(workers.shutdown);
      List<Invocation> launches(String id) =>
          f.read().where((r) => _claudeLaunch(r) && r.stdin == null && r.workerId == id).toList();
      final bin = p.join(f.data, 'bin');
      bool onPath(Invocation r) => (r.path ?? '').split(':').first == bin;
      List<String>? denied(List<String> args) {
        final i = args.indexOf('--disallowedTools');
        return i < 0 ? null : args.sublist(i + 1, i + 4);
      }

      // The command is there, and runs the office's own executable.
      final command = p.join(bin, 'agent-office');
      expect(File(command).statSync().mode & 0x40, isNonZero);
      final help = await Process.run(command, ['queue', '--help']);
      expect('${help.stdout}', contains('agent-office queue add --title'));

      final hired = workers.station('station-queue', 'Ada', 'Fix the typo in the README');
      expect(hired.error, isNull);
      final id = hired.info!.id;
      final first = (await waitFor(() => launches(id), (l) => l.length == 1)).first;
      expect(denied(first.args), ['Edit', 'Write', 'NotebookEdit']);
      expect(
        first.args.indexOf('--disallowedTools'),
        lessThan(first.args.indexOf('--')),
        reason: 'the tools come before the prompt',
      );
      expect(first.args.last, endsWith('Fix the typo in the README'));
      expect(onPath(first), isTrue, reason: 'agent-office is first on its PATH');

      // Woken up carrying on its session, it's still without them.
      expect(workers.handleHook(id, first.hookToken!, 'SessionStart', {'session_id': 'queue-session'}), isTrue);
      await waitFor(() => workers.get(id)?.status, (s) => s == WorkerStatus.exited);
      workers.station('station-queue', 'Grace', 'Also bump the version');
      final second = (await waitFor(() => launches(id), (l) => l.length == 2))[1];
      expect(second.args, containsAll(['--resume', 'queue-session']));
      expect(denied(second.args), ['Edit', 'Write', 'NotebookEdit']);
      expect(second.args.last, 'Also bump the version');
      expect(onPath(second), isTrue);

      // The other board agents keep their tools; they, and a desk worker, get the commands all the same.
      final pulls = workers.station('station-pulls', 'Ada', 'Sum up the open PRs');
      final desk = spawned(workers.spawn('desk-2', 'Ada', 'Fix login'));
      final pullsLaunch = (await waitFor(() => launches(pulls.info!.id), (l) => l.length == 1)).first;
      final deskLaunch = (await waitFor(() => launches(desk.id), (l) => l.length == 1)).first;
      expect(denied(pullsLaunch.args), isNull);
      expect(onPath(pullsLaunch), isTrue);
      expect(denied(deskLaunch.args), isNull);
      expect(onPath(deskLaunch), isTrue, reason: "office-workers is first on a desk worker's PATH");
    },
  );

  // --- #97 #91: acting it out, and when it started waiting ----------------------------------------

  test(
    'a Claude worker acts out its latest tool call, and puts its head in its hands when its tests keep failing',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_EXIT_MS': '5000', 'FAKE_AGENT_LOG': f.log});
      final workers = manager(f, f.claude, [], env);
      addTearDown(workers.shutdown);
      final worker = spawned(workers.spawn('desk-1', 'test', 'make the tests pass'));
      final launch = (await waitFor(f.read, (r) => r.any(_claudeLaunch))).firstWhere(_claudeLaunch);
      final settings = jsonDecode(File(launch.args[launch.args.indexOf('--settings') + 1]).readAsStringSync());
      expect(
        (settings['hooks'] as Map).containsKey('PostToolUseFailure'),
        isTrue,
        reason: 'failed tool calls are reported',
      );

      final token = launch.hookToken!;
      void hook(String event, Map<String, Object?> payload) =>
          expect(workers.handleHook(worker.id, token, event, {'session_id': 'acting', ...payload}), isTrue);
      WorkerAction? action() => workers.get(worker.id)?.action;
      const npmTest = {
        'tool_name': 'Bash',
        'tool_input': {'command': 'npm test 2>&1 | tail -5'},
      };
      hook('SessionStart', {});
      hook('UserPromptSubmit', {'prompt': 'make the tests pass'});
      expect(action(), isNull);
      hook('PreToolUse', {
        'tool_name': 'Read',
        'tool_input': {'file_path': 'src/a.ts'},
      });
      expect(action(), WorkerAction.read);
      hook('PreToolUse', npmTest);
      expect(action(), WorkerAction.test);
      // Failed once (by exit code): still watching. An interrupt isn't a failure.
      hook('PostToolUseFailure', {...npmTest, 'error': 'Exit code 1\n# fail 2', 'is_interrupt': false});
      hook('PostToolUseFailure', {...npmTest, 'error': 'Interrupted', 'is_interrupt': true});
      expect(action(), WorkerAction.test);
      hook('PreToolUse', {
        'tool_name': 'Edit',
        'tool_input': {'file_path': 'src/a.ts'},
      });
      expect(action(), WorkerAction.edit);
      // Failed again, by the summary it printed through the pipe: head in hands, until its next tool call.
      hook('PreToolUse', npmTest);
      hook('PostToolUse', {
        ...npmTest,
        'tool_response': {'stdout': '# tests 5\n# pass 3\n# fail 2', 'stderr': ''},
      });
      expect(action(), WorkerAction.failing);
      hook('PreToolUse', npmTest);
      expect(action(), WorkerAction.test);
      // A pass ends the streak: one more failure isn't "again and again".
      hook('PostToolUse', {
        ...npmTest,
        'tool_response': {'stdout': '# tests 5\n# pass 5\n# fail 0', 'stderr': ''},
      });
      hook('PreToolUse', npmTest);
      hook('PostToolUseFailure', {...npmTest, 'error': 'Exit code 1'});
      expect(action(), WorkerAction.test);
      // A failing command that isn't a test run doesn't count.
      hook('PostToolUseFailure', {
        'tool_name': 'Bash',
        'tool_input': {'command': 'git push'},
        'error': 'Exit code 1',
      });
      expect(action(), WorkerAction.test);
      hook('Stop', {});
      expect(workers.get(worker.id)?.status, WorkerStatus.done);
      expect(action(), isNull);
    },
  );

  test('a worker is stamped with when it started waiting on someone, afresh each time', () async {
    final f = Fixture();
    addTearDown(f.close);
    final workers = manager(f, f.claude, [], isolatedEnv(f, {'FAKE_AGENT_LOG': f.log}));
    addTearDown(workers.shutdown);
    final worker = spawned(workers.spawn('desk-1', 'test', 'fix the login'));
    final token = (await waitFor(f.read, (r) => r.any(_claudeLaunch))).firstWhere(_claudeLaunch).hookToken!;
    void hook(String event, [Map<String, Object?> extra = const {}]) =>
        workers.handleHook(worker.id, token, event, {'session_id': 'waiting', ...extra});
    WorkerInfo now() => workers.get(worker.id)!;
    hook('SessionStart');
    hook('UserPromptSubmit', {'prompt': 'fix the login'});
    expect(now().status, WorkerStatus.working);
    expect(now().waitingSince, isNull);
    final before = DateTime.now().millisecondsSinceEpoch;
    hook('PermissionRequest', {
      'tool_name': 'Bash',
      'tool_input': {'command': 'npm test'},
    });
    expect(now().status, WorkerStatus.needsInput);
    final asked = now().waitingSince!;
    expect(asked, inInclusiveRange(before, DateTime.now().millisecondsSinceEpoch));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    hook('PostToolUse', {'tool_name': 'Bash'});
    hook('Stop');
    expect(now().status, WorkerStatus.done);
    expect(now().waitingSince!, greaterThan(asked), reason: 'finishing is a new wait');
  });

  test('who has a terminal open is told by connection as well as by name', () async {
    final f = Fixture();
    addTearDown(f.close);
    final updates = <WorkerInfo>[];
    final workers = manager(f, f.claude, updates, isolatedEnv(f, {'FAKE_AGENT_LOG': f.log}));
    addTearDown(workers.shutdown);
    final worker = spawned(workers.spawn('desk-1', 'test', 'fix the login'));
    workers.attach(worker.id, 'c1', 'Ada');
    workers.attach(worker.id, 'c2', 'Ada');
    expect(workers.get(worker.id)!.viewers, ['Ada']);
    expect(workers.get(worker.id)!.viewerIds, ['c1', 'c2']);
    final told = updates.length;
    workers.detach(worker.id, 'c1');
    expect(updates.length, told + 1, reason: 'the same names, but one window fewer');
    expect(workers.get(worker.id)!.viewerIds, ['c2']);
  });

  // --- #140: a restart carries on whoever it cut off ---------------------------------------------

  test('a restart that takes a mid-turn worker down resumes it with continue; a finished one just wakes up', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
    final before = manager(f, f.claude, [], env);
    // Never started, so its terminals run in-process and go down with it.
    await _hireInState(f, before, 'desk-1', 'mid-turn', WorkerStatus.working);
    await _hireInState(f, before, 'desk-2', 'asking', WorkerStatus.needsInput);
    await _hireInState(f, before, 'desk-3', 'finished', WorkerStatus.done);
    await before.shutdown(true);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final after = manager(f, f.claude, [], env);
    addTearDown(after.shutdown);
    await after.start();
    final resumed = (await waitFor(() => _launches(f), (x) => x.length >= 6)).sublist(3);
    Invocation of(String session) => resumed.firstWhere((r) => r.args.contains(session));
    for (final session in ['mid-turn', 'asking']) {
      expect(of(session).args, contains('--resume'));
      expect(_promptOf(of(session)), carryOnPrompt);
    }
    expect(of('finished').args, contains('--resume'));
    expect(_promptOf(of('finished')), isNull);
  });

  test(
    'a worker whose terminal outlives the office is picked back up mid-turn, not relaunched or told to continue',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
      final before = manager(f, f.claude, [], env);
      await before.start();
      final worker = await _hireInState(f, before, 'desk-1', 'kept', WorkerStatus.working);
      await before.shutdown(true);

      final after = manager(f, f.claude, [], env);
      addTearDown(after.shutdown);
      await after.start();
      expect(after.get(worker.id)?.status, WorkerStatus.working);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(_launches(f).length, 1);
    },
  );

  test(
    'a worker whose terminal was in the host when an older office went down carries on if the host is gone',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      // workers.json as the office before midTurn left it: only the host terminal's status says it was mid-turn.
      Map<String, Object?> saved(String id, String deskId, String sessionId, String status) => {
        'id': id,
        'kind': 'agent',
        'provider': 'claude',
        'deskId': deskId,
        'name': id,
        'sessionId': sessionId,
        'hookToken': '$id-token',
        'pty': {'id': '$id-pty', 'status': status, 'acked': true},
      };
      File(p.join(f.data, 'workers.json')).writeAsStringSync(
        jsonEncode([
          saved('upgraded', 'desk-1', 'was-working', 'working'),
          saved('idle', 'desk-2', 'was-done', 'done'),
        ]),
      );
      final workers = manager(f, f.claude, [], isolatedEnv(f, {'FAKE_AGENT_LOG': f.log}));
      addTearDown(workers.shutdown);
      await workers.start();
      final resumed = await waitFor(() => _launches(f), (x) => x.length >= 2);
      expect(_promptOf(resumed.firstWhere((r) => r.args.contains('was-working'))), carryOnPrompt);
      expect(_promptOf(resumed.firstWhere((r) => r.args.contains('was-done'))), isNull);
    },
  );

  test('stopping the office on purpose (Ctrl+C) leaves nothing to carry on', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
    final before = manager(f, f.claude, [], env);
    // Its terminals run in the host, which ends them without telling the office they exited.
    await before.start();
    await _hireInState(f, before, 'desk-1', 'stopped', WorkerStatus.working);
    await before.shutdown(false);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final after = manager(f, f.claude, [], env);
    addTearDown(after.shutdown);
    await after.start();
    final resumed = (await waitFor(() => _launches(f), (x) => x.length >= 2))[1];
    expect(resumed.args, contains('stopped'));
    expect(_promptOf(resumed), isNull);
  });

  // --- #197: a worktree deleted outside the office -----------------------------------------------

  test('a worker whose worktree was deleted outside the office waits, marked lost, instead of failing to start; '
      'rebuilding puts it back and it carries on', () async {
    final f = Fixture();
    addTearDown(f.close);
    String git(String cwd, List<String> args) {
      final r = Process.runSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', ...args], workingDirectory: cwd);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return '${r.stdout}'.trim();
    }

    git(f.root, ['init', '-q', '-b', 'main']);
    File(p.join(f.root, 'a.txt')).writeAsStringSync('a');
    git(f.root, ['add', 'a.txt']);
    git(f.root, ['commit', '-qm', 'init']);
    final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
    WorkerManager officeWith(List<WorkerInfo> updates, List<String> toasts) => WorkerManager(
      f.root,
      f.data,
      f.claude,
      const ['--from-test'],
      _hook,
      WorkerEvents(
        update: updates.add,
        remove: (_) {},
        data: (_, _, _) {},
        screen: (_, _) {},
        toast: (text, _) => toasts.add(text),
      ),
      ledger(f.data),
      env: env,
    );
    final before = officeWith([], []);
    Future<WorkerInfo> hire(String deskId, String session) async {
      final n = _launches(f).length;
      final w = spawned(before.spawn(deskId, 'test', 'task for $session', true));
      final token = (await waitFor(() => _launches(f), (x) => x.length > n)).last.hookToken!;
      expect(before.handleHook(w.id, token, 'SessionStart', {'session_id': session}), isTrue);
      return w;
    }

    final kept = await hire('desk-1', 'kept-branch');
    final gone = await hire('desk-2', 'gone-branch');
    // Kept did some work on its branch; gone's branch goes with its folder.
    final keptDir = p.join(f.root, kept.worktree!.path);
    File(p.join(keptDir, 'work.txt')).writeAsStringSync('work');
    git(keptDir, ['add', 'work.txt']);
    git(keptDir, ['commit', '-qm', 'work']);
    await before.shutdown(true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // Deleted while the office was down, by hand.
    Directory(keptDir).deleteSync(recursive: true);
    Directory(p.join(f.root, gone.worktree!.path)).deleteSync(recursive: true);
    git(f.root, ['worktree', 'prune']);
    git(f.root, ['branch', '-D', gone.worktree!.branch]);

    final toasts = <String>[];
    final after = officeWith([], toasts);
    addTearDown(after.shutdown);
    final launched = _launches(f).length;
    await after.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // Nobody started, nobody was told "could not start": both wait at their desks, marked lost.
    expect(_launches(f).length, launched);
    expect(toasts, isEmpty);
    expect(after.get(kept.id)?.lost, LostBranch.here);
    expect(after.get(gone.id)?.lost, LostBranch.gone);
    expect(after.get(kept.id)?.status, WorkerStatus.offline);
    expect(after.resume(kept.id), matches(RegExp(r'worktree .* was deleted outside agent-office')));
    expect(_launches(f).length, launched);

    // Put back on its own branch, work and all, and it carries on its conversation.
    final back = await after.rebuild(kept.id);
    expect((back.rebuilt, back.note, back.error), (true, null, null));
    expect(git(keptDir, ['rev-parse', '--abbrev-ref', 'HEAD']), kept.worktree!.branch);
    expect(File(p.join(keptDir, 'work.txt')).existsSync(), isTrue);
    expect(after.get(kept.id)?.lost, isNull);
    final resumed = await waitFor(() => _launches(f).sublist(launched), (x) => x.isNotEmpty);
    expect(resumed.first.args, containsAll(['--resume', 'kept-branch']));

    // Its branch gone too: made again from where it started.
    final again = await after.rebuild(gone.id);
    expect(again.rebuilt, isTrue);
    expect(again.note, contains('was deleted too'));
    expect(git(p.join(f.root, gone.worktree!.path), ['rev-parse', 'HEAD']), gone.worktree!.base);
    expect(after.get(gone.id)?.lost, isNull);
    expect(toasts, isEmpty);
  });

  // --- #187 #271: Grok, Muse and Cursor workers --------------------------------------------------

  test('Grok workers isolate GROK_HOME, follow authenticated hooks, and resume their session', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
    final book = ledger(f.data);
    final workers = manager(f, f.claude, [], env, args: const ['--claude-only'], book: book);
    var closed = false;
    addTearDown(() => closed ? null : workers.shutdown());
    final worker = spawned(
      workers.spawn(
        'desk-1',
        'test',
        '- fix the login',
        false,
        WorkerKind.agent,
        AgentProvider.grok,
        'grok-4.6',
        AgentEffort.high,
      ),
    );
    final calls = await waitFor(f.read, (x) => x.any((r) => r.kind == 'grok'));
    final first = calls.firstWhere((r) => r.kind == 'grok');
    final token = first.hookToken!;
    WorkerInfo now() => workers.get(worker.id)!;
    expect(worker.status, WorkerStatus.starting);
    expect(worker.model, 'grok-4.6');
    expect(worker.effort, AgentEffort.high);
    expect(
      first.args,
      containsAll(['--no-alt-screen', '--trust', '--session-id', '--model', 'grok-4.6', '--effort', 'high']),
    );
    expect(first.args.sublist(first.args.length - 2), ['--', '- fix the login']);
    expect(first.args, isNot(contains('--claude-only')));
    expect(first.env['grokHome'], p.join(f.data, 'grok-home'));
    expect(calls.any((r) => r.kind == 'claude' && !r.args.contains('--output-format')), isFalse);
    final sessionId = worker.sessionId!;
    expect(sessionId, matches(RegExp(r'^[0-9a-f-]{36}$')));
    bool hook(String event, [Map<String, Object> extra = const {}]) =>
        workers.handleProviderHook(AgentProvider.grok, worker.id, token, event, {'sessionId': sessionId, ...extra});
    expect(
      workers.handleProviderHook(AgentProvider.grok, worker.id, 'wrong', 'SessionStart', {'sessionId': sessionId}),
      isFalse,
    );
    expect(hook('SessionStart', {'source': 'startup'}), isTrue);
    expect(now().status, WorkerStatus.idle);
    expect(hook('UserPromptSubmit', {'prompt': 'Implement the actual task'}), isTrue);
    expect(now().status, WorkerStatus.working);
    expect(hook('PreToolUse', {'toolName': 'run_terminal_command'}), isTrue);
    expect(hook('Notification', {'notificationType': 'permission_prompt'}), isTrue);
    expect(now().status, WorkerStatus.needsInput);
    expect(hook('Stop', {'subagentType': 'explore'}), isFalse);
    expect(now().status, WorkerStatus.needsInput);
    expect(hook('Stop'), isTrue);
    expect(now().status, WorkerStatus.done);
    expect(workers.handleHook(worker.id, token, 'Stop', {'session_id': 'claude'}), isFalse);
    expect(workers.handleCodexHook(worker.id, token, 'Stop', {'session_id': sessionId}), isFalse);
    expect(now().usage, isNull);
    await workers.shutdown();
    closed = true;

    final restored = manager(f, f.claude, [], env, args: const ['--claude-only']);
    addTearDown(restored.shutdown);
    await restored.start();
    final nextCalls = await waitFor(f.read, (x) => x.where((r) => r.kind == 'grok' && r.stdin == null).length >= 2);
    final next = nextCalls.where((r) => r.kind == 'grok' && r.stdin == null).last;
    expect(next.args, containsAll(['--resume', sessionId]));
    expect(next.args, isNot(contains('--session-id')));
    expect(next.args, isNot(contains('--model')));
    expect(next.hookToken, isNot(token));
    expect(restored.get(worker.id)?.provider, AgentProvider.grok);
    expect(restored.get(worker.id)?.model, 'grok-4.6');
    expect(restored.get(worker.id)?.effort, AgentEffort.high);
    expect(
      restored.handleProviderHook(AgentProvider.grok, worker.id, token, 'Stop', {'sessionId': sessionId}),
      isFalse,
    );
    expect(
      restored.handleProviderHook(AgentProvider.grok, worker.id, next.hookToken!, 'SessionStart', {
        'sessionId': sessionId,
        'source': 'resume',
      }),
      isTrue,
    );
    expect(restored.get(worker.id)?.status, WorkerStatus.idle);
  });

  test('Muse workers isolate XDG, follow authenticated hooks, resume by id, and paste a follow-up prompt', () async {
    final f = Fixture();
    addTearDown(f.close);
    final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
    final workers = manager(f, f.claude, [], env, args: const ['--claude-only']);
    var closed = false;
    addTearDown(() => closed ? null : workers.shutdown());
    final worker = spawned(
      workers.spawn(
        'desk-1',
        'test',
        '- fix the login',
        false,
        WorkerKind.agent,
        AgentProvider.muse,
        'muse-spark-1.3-contributor',
        AgentEffort.high,
      ),
    );
    final first = (await waitFor(f.read, (x) => x.any((r) => r.kind == 'muse'))).firstWhere((r) => r.kind == 'muse');
    final token = first.hookToken!;
    WorkerInfo now() => workers.get(worker.id)!;
    expect(worker.status, WorkerStatus.starting);
    expect(worker.sessionId, isNull);
    expect(
      first.args,
      containsAll(['--trust-workspace', '--model', 'muse-spark-1.3-contributor', '--reasoning-effort', 'high']),
    );
    expect(first.args.sublist(first.args.length - 2), ['--', '- fix the login']);
    expect(first.args, isNot(contains('resume')));
    expect(first.args, isNot(contains('--claude-only')));
    expect(first.env['xdgConfig'], p.join(f.data, 'muse-home', 'config'));
    expect(first.env['xdgData'], p.join(f.data, 'muse-home', 'share'));
    expect(first.env['xdgState'], p.join(f.data, 'muse-home', 'state'));
    const sessionId = 'muse-root';
    bool hook(String event, [Map<String, Object> extra = const {}]) =>
        workers.handleProviderHook(AgentProvider.muse, worker.id, token, event, {'session_id': sessionId, ...extra});
    expect(hook('SessionStart', {'source': 'startup'}), isTrue);
    expect(now().status, WorkerStatus.idle);
    expect(now().sessionId, sessionId);
    expect(hook('UserPromptSubmit', {'prompt': 'Implement the actual task'}), isTrue);
    expect(now().status, WorkerStatus.working);
    expect(hook('PreToolUse', {'tool_name': 'run_terminal_command'}), isTrue);
    expect(hook('PermissionRequest', {'tool_name': 'shell'}), isTrue);
    expect(now().status, WorkerStatus.needsInput);
    expect(hook('PostToolUseFailure', {'tool_name': 'shell'}), isTrue);
    expect(now().status, WorkerStatus.working);
    expect(hook('Stop', {'subagent_type': 'explore'}), isFalse);
    expect(hook('Stop'), isTrue);
    expect(now().status, WorkerStatus.done);
    expect(workers.handleProviderHook(AgentProvider.grok, worker.id, token, 'Stop', {'sessionId': sessionId}), isFalse);
    await workers.shutdown();
    closed = true;

    final restored = manager(f, f.claude, [], {...env, 'FAKE_AGENT_EXIT_MS': '1500'}, args: const ['--claude-only']);
    addTearDown(restored.shutdown);
    await restored.start();
    final next = (await waitFor(
      f.read,
      (x) => x.where((r) => r.kind == 'muse' && r.stdin == null).length >= 2,
    )).where((r) => r.kind == 'muse' && r.stdin == null).last;
    expect(next.args, containsAll(['--trust-workspace', 'resume', sessionId]));
    expect(next.args, isNot(contains('--model')));
    expect(next.args, isNot(contains('- fix the login')));
    expect(next.hookToken, isNot(token));
    expect(
      restored.handleProviderHook(AgentProvider.muse, worker.id, next.hookToken!, 'SessionStart', {
        'session_id': sessionId,
        'source': 'resume',
      }),
      isTrue,
    );
    expect(restored.get(worker.id)?.status, WorkerStatus.idle);
    await waitFor(() => restored.get(worker.id)?.status, (s) => s == WorkerStatus.exited);
    expect(restored.resume(worker.id, 'follow-up from the queue'), isNull);
    final launched = (await waitFor(
      f.read,
      (x) => x.where((r) => r.kind == 'muse' && r.stdin == null).length >= 3,
    )).where((r) => r.kind == 'muse' && r.stdin == null).last;
    expect(launched.args, containsAll(['resume', sessionId]));
    expect(launched.args, isNot(contains('follow-up from the queue')));
    expect(
      restored.handleProviderHook(AgentProvider.muse, worker.id, launched.hookToken!, 'SessionStart', {
        'session_id': sessionId,
        'source': 'resume',
      }),
      isTrue,
    );
    await waitFor(
      f.read,
      (x) => x.any((r) => r.kind == 'muse' && (r.stdin?.contains('follow-up from the queue') ?? false)),
    );
  });

  test(
    'Cursor workers keep their hooks in their folder, follow them, and resume their chat with a follow-up prompt',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final env = isolatedEnv(f, {'FAKE_AGENT_LOG': f.log});
      final hooksFile = p.join(f.root, '.cursor', 'hooks.json');
      Map? entries() =>
          File(hooksFile).existsSync() ? (jsonDecode(File(hooksFile).readAsStringSync()) as Map)['hooks'] as Map : null;
      final workers = manager(f, f.claude, [], env, args: const ['--claude-only']);
      var closed = false;
      addTearDown(() => closed ? null : workers.shutdown());
      expect(
        workers.spawn('desk-2', 'test', 'bad', false, WorkerKind.agent, AgentProvider.cursor, '--force').error,
        contains('Invalid Cursor model'),
      );
      expect(
        workers
            .spawn('desk-2', 'test', 'bad', false, WorkerKind.agent, AgentProvider.cursor, 'gpt-5', AgentEffort.high)
            .error,
        matches(RegExp('effort', caseSensitive: false)),
      );
      final worker = spawned(
        workers.spawn('desk-1', 'test', '- fix the login', false, WorkerKind.agent, AgentProvider.cursor, 'gpt-5'),
      );
      // The provider is "cursor"; its executable is cursor-agent.
      final first = (await waitFor(
        f.read,
        (x) => x.any((r) => r.kind == 'cursor-agent'),
      )).firstWhere((r) => r.kind == 'cursor-agent');
      final token = first.hookToken!;
      WorkerInfo now() => workers.get(worker.id)!;
      // A resumed chat fires no sessionStart, so it never waits for one: it's idle as soon as it runs.
      expect(now().status, WorkerStatus.idle);
      expect(first.args, ['--trust', '--model', 'gpt-5', '--', '- fix the login']);
      // Its hooks are in the folder it runs in, one entry an event, each naming this worker.
      expect(entries()!.keys, [
        'sessionStart',
        'beforeSubmitPrompt',
        'preToolUse',
        'postToolUse',
        'postToolUseFailure',
        'stop',
      ]);
      expect(((entries()!['stop'] as List)[0] as Map)['command'] as String, endsWith(" 'stop' '${worker.id}'"));
      const sessionId = '0b9a7d0e-5c1f-4a57-9d55-3a1d2f6f0c11';
      bool hook(String event, [Map<String, Object> extra = const {}]) => workers.handleProviderHook(
        AgentProvider.cursor,
        worker.id,
        token,
        event,
        {'conversation_id': sessionId, ...extra},
      );
      expect(hook('sessionStart', {'composer_mode': 'agent'}), isTrue);
      expect(now().sessionId, sessionId);
      expect(hook('beforeSubmitPrompt', {'prompt': 'Implement the actual task'}), isTrue);
      expect(now().status, WorkerStatus.working);
      expect(now().activity, 'Implement the actual task');
      expect(hook('preToolUse', {'tool_name': 'Read', 'tool_use_id': 'tool-1'}), isTrue);
      expect(now().activity, 'Read');
      expect(now().action, WorkerAction.read);
      expect(hook('stop', {'subagent_id': 'child-1'}), isFalse);
      expect(hook('afterAgentResponse', {'text': 'private'}), isFalse);
      expect(hook('stop', {'status': 'completed'}), isTrue);
      expect(now().status, WorkerStatus.done);
      // A chat started over inside the terminal fires no sessionStart: its first prompt takes the desk to it.
      expect(
        workers.handleProviderHook(AgentProvider.cursor, worker.id, token, 'beforeSubmitPrompt', {
          'conversation_id': 'second-chat',
          'prompt': 'Something else',
        }),
        isTrue,
      );
      expect(now().sessionId, 'second-chat');
      expect(now().status, WorkerStatus.working);
      // The office stops, and the worker with it: nothing of its hooks is left in the project.
      await workers.shutdown();
      closed = true;
      expect(File(hooksFile).existsSync(), isFalse);

      final restored = manager(f, f.claude, [], {...env, 'FAKE_AGENT_EXIT_MS': '1500'}, args: const ['--claude-only']);
      addTearDown(restored.shutdown);
      await restored.start();
      final next = (await waitFor(
        f.read,
        (x) => x.where((r) => r.kind == 'cursor-agent' && r.stdin == null).length >= 2,
      )).where((r) => r.kind == 'cursor-agent' && r.stdin == null).last;
      expect(next.args, ['--trust', '--resume=second-chat']);
      expect(next.hookToken, isNot(token));
      expect((entries()!['stop'] as List).length, 1);
      // Its process ends: its entries go, and the file with them.
      await waitFor(() => restored.get(worker.id)?.status, (s) => s == WorkerStatus.exited);
      expect(File(hooksFile).existsSync(), isFalse);
    },
  );
}

bool _claudeLaunch(Invocation r) => r.kind == 'claude' && r.args.contains('--settings');

/// Each Claude worker launch so far (not the task namer's calls, nor what it read from its terminal), oldest first.
List<Invocation> _launches(Fixture f) => f.read().where((r) => _claudeLaunch(r) && r.stdin == null).toList();

/// What a launch was told to do: the prompt after `--`, if any.
String? _promptOf(Invocation r) => r.args.contains('--') ? r.args[r.args.indexOf('--') + 1] : null;

/// Hires a Claude worker and puts its session in [state]: mid-turn (working, needs_input) or finished (done).
Future<WorkerInfo> _hireInState(
  Fixture f,
  WorkerManager workers,
  String deskId,
  String session,
  WorkerStatus state,
) async {
  final before = _launches(f).length;
  final worker = spawned(workers.spawn(deskId, 'test', 'task for $session'));
  final token = (await waitFor(() => _launches(f), (x) => x.length > before)).last.hookToken!;
  void hook(String event, [Map<String, Object?> extra = const {}]) =>
      expect(workers.handleHook(worker.id, token, event, {'session_id': session, ...extra}), isTrue);
  hook('SessionStart');
  hook('UserPromptSubmit', {'prompt': 'task for $session'});
  if (state == WorkerStatus.needsInput) {
    hook('PermissionRequest', {
      'tool_name': 'Bash',
      'tool_input': {'command': 'npm test'},
    });
  }
  if (state == WorkerStatus.done) hook('Stop');
  expect(workers.get(worker.id)?.status, state);
  return worker;
}

class _Prompts implements PromptSource {
  _Prompts(this._text, this._agent);
  final String Function(PromptId id) _text;
  final AgentChoice? _agent;
  @override
  String text(PromptId id) => _text(id);
  @override
  AgentChoice? agent() => _agent;
}
