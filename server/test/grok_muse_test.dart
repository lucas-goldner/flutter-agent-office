// Upstream's tests/grok.test.ts and tests/muse.test.ts. Their hook helpers are the office's own
// executable here (`agent-office hook grok|muse <event>`), run in-process.
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/grok.dart';
import 'package:agent_office_server/src/muse.dart';
import 'package:agent_office_server/src/providers/providers.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_handle.dart';
import 'support/hook_bridge.dart';

const _office = ['/opt/agent office/agent-office'];

void main() {
  group('Grok', () {
    test('normalizes bounded root Grok hook payloads from camelCase or snake_case', () {
      expect(
        normalizeGrokHook('SessionStart', {
          'sessionId': 'sess-1',
          'source': 'startup',
          'toolInput': {'command': 'secret'},
        })?.toJson(),
        {'sessionId': 'sess-1', 'event': 'SessionStart', 'source': 'startup'},
      );
      expect(
        normalizeGrokHook('UserPromptSubmit', {
          'session_id': 'sess-1',
          'prompt': '  fix the login  ',
          'model': 'secret-model',
        })?.toJson(),
        {'sessionId': 'sess-1', 'event': 'UserPromptSubmit', 'prompt': 'fix the login'},
      );
      expect(
        normalizeGrokHook('PreToolUse', {
          'sessionId': 'sess-1',
          'toolName': 'run_terminal_command',
          'toolUseId': 'tool-1',
        })?.toJson(),
        {'sessionId': 'sess-1', 'event': 'PreToolUse', 'tool': 'run_terminal_command', 'toolUseId': 'tool-1'},
      );
      expect(
        normalizeGrokHook('Notification', {'sessionId': 'sess-1', 'notificationType': 'permission_prompt'})?.toJson(),
        {'sessionId': 'sess-1', 'event': 'Notification', 'notificationType': 'permission_prompt'},
      );
    });

    test('rejects unknown, malformed, empty, oversized, and child-scoped Grok events', () {
      expect(validateGrokHook('Unknown', {'sessionId': 'x'}), isFalse);
      expect(validateGrokHook('Stop', null), isFalse);
      expect(validateGrokHook('Stop', {'sessionId': ''}), isFalse);
      expect(validateGrokHook('Stop', {'sessionId': 'x' * 161}), isFalse);
      expect(validateGrokHook('Stop', {'sessionId': 'x', 'subagentType': 'explore'}), isFalse);
      expect(validateGrokHook('Stop', {'sessionId': 'x', 'agent_id': 'child-1'}), isFalse);
    });

    test('strips launch flags the office always sets itself', () {
      expect(
        withoutGrokLaunchArgs([
          '--keep', 'yes', '--model', 'old', '--no-alt-screen', '--trust', '--session-id', 'abc', '--effort', 'high', //
        ]),
        ['--keep', 'yes'],
      );
    });

    test("writes an isolated GROK_HOME whose hooks run the office's own executable", () {
      final dir = Directory.systemTemp.createTempSync('agent-office-grok-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final written = writeGrokHome(dir.path, _office);
      expect(written.home, p.join(dir.path, 'grok-home'));
      expect(written.socket, p.join(dir.path, 'grok-leader.sock'));
      final file = File(p.join(written.home, 'hooks', 'agent-office.json'));
      if (!Platform.isWindows) expect(file.statSync().mode & 0x1ff, 0x180); // 0600
      final hooks = (jsonDecode(file.readAsStringSync()) as Map)['hooks'] as Map;
      for (final event in grokHookEvents) {
        final hook = ((hooks[event] as List).single as Map)['hooks'] as List;
        expect(hook.single, {
          'type': 'command',
          'command': "'/opt/agent office/agent-office' 'hook' 'grok' '$event'",
          'timeout': 3,
        });
      }
      expect(file.readAsStringSync(), isNot(contains('node')));
    });

    test('helper forwards only the bounded root event fields to the authenticated bridge', () async {
      final bridge = await Bridge.start();
      try {
        final env = {
          'AGENT_OFFICE_HOOK_URL': bridge.url,
          'AGENT_OFFICE_HOOK_TOKEN': 'hook-token',
          'AGENT_OFFICE_WORKER_ID': 'worker-1',
        };
        final stdout = await hook(
          ['grok', 'UserPromptSubmit'],
          jsonEncode({
            'sessionId': 'sess-1',
            'prompt': 'fix it',
            'toolInput': {'command': 'private'},
            'subagentType': '',
            'hookEventName': 'forged',
          }),
          env,
        );
        expect(stdout, '{}');
        final received = bridge.requests.single;
        expect(received.authorization, 'Bearer hook-token');
        expect(received.url, '/hooks/grok?worker=worker-1&event=UserPromptSubmit');
        expect(jsonDecode(received.body), {
          'session_id': 'sess-1',
          'hook_event_name': 'UserPromptSubmit',
          'prompt': 'fix it',
        });
        // Bounded stdin, a child session, and a missing bridge: nothing is sent.
        expect(await hook(['grok', 'Stop'], jsonEncode({'sessionId': 's', 'x': 'y' * (64 * 1024)}), env), '');
        expect(await hook(['grok', 'Stop'], jsonEncode({'sessionId': 's', 'agent_id': 'child'}), env), '');
        expect(
          await hook(['grok', 'Stop'], jsonEncode({'sessionId': 's'}), {...env}..remove('AGENT_OFFICE_WORKER_ID')),
          '',
        );
        expect(bridge.requests.length, 1);
      } finally {
        await bridge.close();
      }
    });

    test('a Grok worker runs in the office GROK_HOME on a session id the office picks, and resumes it', () {
      final dir = Directory.systemTemp.createTempSync('agent-office-grok-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final auth = Directory(p.join(dir.path, 'user-grok'))..createSync();
      File(p.join(auth.path, 'auth.json')).writeAsStringSync('{}');
      const grok = GrokAdapter();
      final setup =
          grok.prepare(ProviderFloor(dataDir: dir.path, office: _office, env: {'GROK_HOME': auth.path})) as GrokSetup;
      expect(setup.authPath, p.join(auth.path, 'auth.json'));
      final h = handleFor(AgentProvider.grok, model: 'grok-4.6', effort: AgentEffort.high);
      final fresh = grok.launch(
        LaunchInput(h: h, args: ['--model', 'old', '--keep'], prompt: 'fix it', cwd: dir.path, setup: setup),
      );
      final session = h.info.sessionId!;
      expect(session, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(fresh.args, [
        '--keep', '--no-alt-screen', '--trust', '--leader-socket', setup.socket, '--session-id', session, //
        '--model', 'grok-4.6', '--effort', 'high', '--', 'fix it',
      ]);
      expect(fresh.rotateToken, isTrue);
      expect(fresh.env, {'GROK_HOME': setup.home, 'GROK_AUTH_PATH': p.join(auth.path, 'auth.json')});
      final resumed = grok.launch(LaunchInput(h: h, args: [], resumeSessionId: session, cwd: dir.path, setup: setup));
      expect(resumed.args, ['--no-alt-screen', '--trust', '--leader-socket', setup.socket, '--resume', session]);
    });

    test('Grok hooks drive the worker through its turn', () {
      final h = handleFor(AgentProvider.grok, sessionId: 'sess-1');
      final handle = const GrokAdapter().hook!.handle;
      expect(handle(h, 'SessionStart', {'sessionId': 'sess-1', 'source': 'startup'}), isTrue);
      expect(h.info.status, WorkerStatus.idle);
      handle(h, 'UserPromptSubmit', {'sessionId': 'sess-1', 'prompt': 'fix it'});
      expect(h.info.status, WorkerStatus.working);
      expect(h.info.activity, 'fix it');
      handle(h, 'PreToolUse', {'sessionId': 'sess-1', 'toolName': 'ask_user_question'});
      expect(h.info.status, WorkerStatus.needsInput);
      handle(h, 'PostToolUse', {'sessionId': 'sess-1', 'toolName': 'ask_user_question'});
      expect(h.info.status, WorkerStatus.working);
      // Another session's events don't touch this one, until it starts.
      expect(handle(h, 'Stop', {'sessionId': 'other'}), isFalse);
      expect(h.info.status, WorkerStatus.working);
      handle(h, 'StopCancelled', {'sessionId': 'sess-1'});
      expect(h.info.status, WorkerStatus.done);
    });
  });

  group('Muse', () {
    test('normalizes bounded root Muse hook payloads from camelCase or snake_case', () {
      expect(
        normalizeMuseHook('SessionStart', {
          'session_id': 'sess-1',
          'source': 'startup',
          'last_assistant_message': 'secret',
        })?.toJson(),
        {'sessionId': 'sess-1', 'event': 'SessionStart', 'source': 'startup'},
      );
      expect(
        normalizeMuseHook('', {
          'hook_event_name': 'UserPromptSubmit',
          'session_id': 'sess-1',
          'prompt': '  fix the login  ',
        })?.toJson(),
        {'sessionId': 'sess-1', 'event': 'UserPromptSubmit', 'prompt': 'fix the login'},
      );
      expect(
        normalizeMuseHook('PreToolUse', {
          'sessionId': 'sess-1',
          'tool_name': 'run_terminal_command',
          'tool_use_id': 'tool-1',
        })?.toJson(),
        {'sessionId': 'sess-1', 'event': 'PreToolUse', 'tool': 'run_terminal_command', 'toolUseId': 'tool-1'},
      );
      expect(normalizeMuseHook('PermissionRequest', {'session_id': 'sess-1', 'tool': 'shell'})?.toJson(), {
        'sessionId': 'sess-1',
        'event': 'PermissionRequest',
        'tool': 'shell',
      });
    });

    test('rejects unknown, malformed, empty, oversized, and child-scoped Muse events', () {
      expect(validateMuseHook('Unknown', {'session_id': 'x'}), isFalse);
      expect(validateMuseHook('Stop', null), isFalse);
      expect(validateMuseHook('Stop', {'session_id': ''}), isFalse);
      expect(validateMuseHook('Stop', {'session_id': 'x' * 161}), isFalse);
      expect(validateMuseHook('Stop', {'session_id': 'x', 'subagent_type': 'explore'}), isFalse);
      expect(validateMuseHook('Stop', {'session_id': 'x', 'parent_session_id': 'root'}), isFalse);
    });

    test('strips launch flags the office always sets itself', () {
      expect(
        withoutMuseLaunchArgs([
          '--keep', 'yes', '--model', 'old', '--trust-workspace', '--yolo', '-w', 'resume', 'abc', //
          '--reasoning-effort', 'high', '--', 'prompt',
        ]),
        ['--keep', 'yes'],
      );
    });

    test("writes an isolated Muse XDG home whose hooks run the office's own executable", () {
      final dir = Directory.systemTemp.createTempSync('agent-office-muse-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final user = Directory(p.join(dir.path, 'user-muse'))..createSync(recursive: true);
      File(p.join(user.path, 'settings.json')).writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'provider': 'meta',
          'model': 'muse-spark-1.3-contributor',
          'managed_hooks_path': '/tmp/orca-hooks.json',
        }),
      );
      File(p.join(user.path, 'auth.json')).writeAsStringSync('{"token":"secret"}');
      final written = writeMuseHome(dir.path, _office, user.path);
      expect(written.home, p.join(dir.path, 'muse-home'));
      final settings = jsonDecode(File(p.join(written.configHome, 'muse', 'settings.json')).readAsStringSync()) as Map;
      expect(settings['provider'], 'meta');
      expect(settings['model'], 'muse-spark-1.3-contributor');
      expect(settings.containsKey('managed_hooks_path'), isFalse);
      for (final event in museHookEvents) {
        final hook = (((settings['hooks'] as Map)[event] as List).single as Map)['hooks'] as List;
        expect((hook.single as Map)['command'], "'/opt/agent office/agent-office' 'hook' 'muse' '$event'");
      }
      // The person's sign-in is linked in, not copied about.
      expect(File(p.join(written.configHome, 'muse', 'auth.json')).readAsStringSync(), '{"token":"secret"}');
      expect(Directory(written.dataHome).existsSync() && Directory(written.stateHome).existsSync(), isTrue);
    });

    test('helper forwards only the bounded root event fields to the authenticated bridge', () async {
      final bridge = await Bridge.start();
      try {
        final stdout = await hook(
          ['muse', 'UserPromptSubmit'],
          jsonEncode({
            'session_id': 'sess-1',
            'prompt': 'fix it',
            'last_assistant_message': 'private',
            'hook_event_name': 'UserPromptSubmit',
          }),
          {
            'AGENT_OFFICE_HOOK_URL': bridge.url,
            'AGENT_OFFICE_HOOK_TOKEN': 'hook-token',
            'AGENT_OFFICE_WORKER_ID': 'worker-1',
          },
        );
        expect(stdout, '{}');
        final received = bridge.requests.single;
        expect(received.authorization, 'Bearer hook-token');
        expect(received.url, '/hooks/muse?worker=worker-1&event=UserPromptSubmit');
        expect(jsonDecode(received.body), {
          'session_id': 'sess-1',
          'hook_event_name': 'UserPromptSubmit',
          'prompt': 'fix it',
        });
      } finally {
        await bridge.close();
      }
    });

    test('a resumed Muse worker gets its prompt typed in once its session has started', () {
      final dir = Directory.systemTemp.createTempSync('agent-office-muse-');
      addTearDown(() => dir.deleteSync(recursive: true));
      const muse = MuseAdapter();
      final setup =
          muse.prepare(ProviderFloor(dataDir: dir.path, office: _office, env: {'HOME': dir.path})) as MuseHome;
      final h = handleFor(AgentProvider.muse, model: 'muse-spark-1.3', effort: AgentEffort.low, sessionId: 'sess-1');
      final fresh = muse.launch(LaunchInput(h: h, args: ['--yolo'], prompt: 'fix it', cwd: dir.path, setup: setup));
      expect(fresh.args, [
        '--trust-workspace',
        '--model',
        'muse-spark-1.3',
        '--reasoning-effort',
        'low',
        '--',
        'fix it',
      ]);
      expect(fresh.env, {
        'XDG_CONFIG_HOME': setup.configHome,
        'XDG_DATA_HOME': setup.dataHome,
        'XDG_STATE_HOME': setup.stateHome,
      });
      final resumed = muse.launch(
        LaunchInput(h: h, args: [], prompt: 'carry on', resumeSessionId: 'sess-1', cwd: dir.path, setup: setup),
      );
      expect(resumed.args, ['--trust-workspace', 'resume', 'sess-1']);
      expect(h.pendingPrompt, 'carry on');
      muse.hook!.handle(h, 'SessionStart', {'session_id': 'sess-1', 'source': 'resume'});
      expect(h.prompts, ['carry on']);
      expect(h.pendingPrompt, isNull);
      expect(h.info.status, WorkerStatus.idle);
    });
  });
}
