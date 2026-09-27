@TestOn('mac-os || linux')
@Timeout(Duration(seconds: 120))
library;

import 'dart:convert';
import 'dart:io';

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
    for (final name in ['claude', 'opencode', 'custom-agent', 'codex']) {
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
}) => WorkerManager(f.root, f.data, cmd, args, _hook, events(updates), book ?? ledger(f.data), env: env);

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

  test('workers reject models for non-OpenCode providers and malformed model ids', () async {
    final f = Fixture();
    addTearDown(f.close);
    final workers = manager(f, f.claude, [], {...Platform.environment, 'FAKE_AGENT_LOG': f.log});
    addTearDown(workers.shutdown);
    String? error(String desk, WorkerKind kind, AgentProvider? provider, String model) =>
        workers.spawn(desk, 'test', 'bad', false, kind, provider, model).error;
    expect(
      error('desk-1', WorkerKind.agent, AgentProvider.claude, 'openai/gpt-5'),
      matches(RegExp('model|OpenCode', caseSensitive: false)),
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
}
