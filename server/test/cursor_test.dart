// Upstream's tests/cursor.test.ts. The hook helper is the office's own executable here
// (`agent-office hook cursor <event> <worker>`), run in-process.
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/cursor.dart';
import 'package:agent_office_server/src/providers/providers.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_handle.dart';
import 'support/hook_bridge.dart';

const _office = ['/opt/agent office/agent-office'];

Directory _scratch() {
  final dir = Directory.systemTemp.createTempSync('agent-office-cursor-');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

String _hooksFile(String cwd) => p.join(cwd, '.cursor', 'hooks.json');
Map<String, dynamic> _readHooks(String cwd) =>
    jsonDecode(File(_hooksFile(cwd)).readAsStringSync()) as Map<String, dynamic>;
List _entries(String cwd, String event) => (_readHooks(cwd)['hooks'] as Map)[event] as List;

void main() {
  test('maps Cursor hook events onto the lifecycle, keeping only bounded root fields', () {
    expect(
      normalizeCursorHook('sessionStart', {
        'conversation_id': 'chat-1',
        'session_id': 'chat-1',
        'model': 'gpt-5',
        'composer_mode': 'agent',
        'is_background_agent': false,
        'transcript_path': '/secret',
      })?.toJson(),
      {'sessionId': 'chat-1', 'event': 'SessionStart'},
    );
    expect(
      normalizeCursorHook('beforeSubmitPrompt', {
        'conversation_id': 'chat-1',
        'prompt': '  fix the login  ',
        'attachments': [
          {'file_path': '/secret'},
        ],
      })?.toJson(),
      {'sessionId': 'chat-1', 'event': 'UserPromptSubmit', 'prompt': 'fix the login'},
    );
    expect(
      normalizeCursorHook('preToolUse', {
        'conversation_id': 'chat-1',
        'tool_name': 'Shell',
        'tool_use_id': 'tool-1',
        'tool_input': {'command': 'cat .env'},
        'agent_message': 'private',
      })?.toJson(),
      {'sessionId': 'chat-1', 'event': 'PreToolUse', 'tool': 'Shell', 'toolUseId': 'tool-1'},
    );
    expect(
      normalizeCursorHook('postToolUse', {
        'conversation_id': 'chat-1',
        'tool_name': 'Shell',
        'tool_use_id': 'tool-1',
        'tool_output': 'private',
      })?.toJson(),
      {'sessionId': 'chat-1', 'event': 'PostToolUse', 'tool': 'Shell', 'toolUseId': 'tool-1'},
    );
    expect(
      normalizeCursorHook('postToolUseFailure', {
        'conversation_id': 'chat-1',
        'tool_name': 'Shell',
        'failure_type': 'permission_denied',
        'error_message': 'private',
      })?.toJson(),
      {'sessionId': 'chat-1', 'event': 'PostToolUseFailure', 'tool': 'Shell'},
    );
    expect(normalizeCursorHook('stop', {'session_id': 'chat-1', 'status': 'completed', 'loop_count': 0})?.toJson(), {
      'sessionId': 'chat-1',
      'event': 'Stop',
    });
  });

  test('rejects unknown, malformed, child-scoped and unsafe Cursor events', () {
    expect(normalizeCursorHook('afterAgentResponse', {'conversation_id': 'chat-1', 'text': 'private'}), isNull);
    expect(normalizeCursorHook('Stop', {'conversation_id': 'chat-1'}), isNull);
    expect(normalizeCursorHook('stop', null), isNull);
    expect(normalizeCursorHook('stop', {}), isNull);
    expect(normalizeCursorHook('stop', {'conversation_id': ''}), isNull);
    expect(normalizeCursorHook('stop', {'conversation_id': 'x' * 129}), isNull);
    expect(normalizeCursorHook('stop', {'conversation_id': 'chat-1', 'subagent_id': 'child-1'}), isNull);
    expect(
      normalizeCursorHook('preToolUse', {'conversation_id': 'chat-1', 'parent_conversation_id': 'chat-0'}),
      isNull,
    );
    expect(normalizeCursorHook('sessionStart', {'conversation_id': 'chat-1', 'is_background_agent': true}), isNull);
    // A chat id goes back on the command line when the worker is resumed: nothing that reads as a flag.
    expect(normalizeCursorHook('sessionStart', {'conversation_id': '--force'}), isNull);
    expect(normalizeCursorHook('sessionStart', {'conversation_id': 'chat 1'}), isNull);
  });

  test('strips launch flags the office sets itself and the ones that skip permission prompts', () {
    expect(
      withoutCursorLaunchArgs([
        '--keep', 'yes', '--model', 'gpt-5', '--force', '-f', '--yolo', '--trust', '--resume', 'abc', '--continue', //
        '-p', '--output-format', 'json', '--workspace=/x', '-w', '--mode', 'plan',
      ]),
      ['--keep', 'yes', '--mode', 'plan'],
    );
    expect(withoutCursorLaunchArgs(['--resume', '--sandbox', 'enabled', '--', 'a prompt']), ['--sandbox', 'enabled']);
  });

  test('Cursor model ids are checked before they reach the command line', () {
    for (final ok in [
      'gpt-5',
      'sonnet-4-thinking',
      'composer-2.5',
      'claude-opus-4-8[context=1m,effort=high,fast=false]',
    ]) {
      expect(isValidCursorModel(ok), isTrue, reason: ok);
    }
    for (final bad in <Object?>[
      '', '--force', '-m', 'gpt 5', 'gpt-5[effort]', 'gpt-5[effort=high', 'gpt-5]', 'a/b', 'gpt-5;rm', 'gpt\u00005', //
      'x' * 129, 42, null,
    ]) {
      expect(isValidCursorModel(bad), isFalse, reason: '$bad');
    }
  });

  test('reads the login screen off the terminal', () {
    expect(cursorBlocked('  v2026.09.08-6caf4ff\n  Press any key to log in...'), contains('signed in'));
    expect(cursorBlocked('→ Add a follow-up'), isNull);
  });

  test("puts a worker's hooks in its folder and takes the file away with them", () {
    final dir = _scratch().path;
    final cwd = p.join(dir, 'worktree');
    Directory(cwd).createSync();
    Process.runSync('git', ['init', '-q', cwd]);
    expect(addCursorHooks(cwd, _office, 'abc123'), isTrue);
    final written = _readHooks(cwd);
    expect(written['version'], 1);
    expect((written['hooks'] as Map).keys, cursorHookEvents.keys);
    for (final MapEntry(key: event, value: entries) in (written['hooks'] as Map).entries) {
      final list = entries as List;
      expect(list.length, 1);
      expect(list[0]['command'], "'/opt/agent office/agent-office' 'hook' 'cursor' '$event' 'abc123'");
      expect(list[0]['timeout'], 5);
    }
    // The office made it, so it's no change of the worker's.
    expect(Process.runSync('git', ['status', '--porcelain'], workingDirectory: cwd).stdout, '');
    // Starting again doesn't double them.
    expect(addCursorHooks(cwd, _office, 'abc123'), isTrue);
    expect(_entries(cwd, 'stop').length, 1);
    removeCursorHooks(cwd, 'abc123');
    expect(File(_hooksFile(cwd)).existsSync(), isFalse);
    expect(Directory(p.join(cwd, '.cursor')).existsSync(), isFalse);
    // Nothing there: nothing to do.
    removeCursorHooks(cwd, 'abc123');
  });

  test('workers sharing a folder each keep their own entries', () {
    final dir = _scratch().path;
    expect(addCursorHooks(dir, _office, 'worker-a'), isTrue);
    expect(addCursorHooks(dir, _office, 'worker-b'), isTrue);
    List<String> owners() => [for (final e in _entries(dir, 'stop')) (e['command'] as String).split(' ').last];
    expect(owners(), ["'worker-a'", "'worker-b'"]);
    removeCursorHooks(dir, 'worker-a');
    expect(owners(), ["'worker-b'"]);
    removeCursorHooks(dir, 'worker-b');
    expect(File(_hooksFile(dir)).existsSync(), isFalse);
  });

  test("a project's own hooks.json keeps its hooks and comes back byte for byte", () {
    final dir = _scratch().path;
    Directory(p.join(dir, '.cursor')).createSync();
    File(p.join(dir, '.cursor', 'rules.md')).writeAsStringSync('be kind\n');
    const original =
        '{\n\t"version": 1,\n\t"hooks": {\n\t\t"stop": [{ "command": "./notify.sh" }],\n\t\t"afterFileEdit": [{ "command": "./format.sh" }]\n\t}\n}';
    File(_hooksFile(dir)).writeAsStringSync(original);
    expect(addCursorHooks(dir, _office, 'abc123'), isTrue);
    expect(_entries(dir, 'stop').length, 2);
    expect(_entries(dir, 'stop')[0]['command'], './notify.sh');
    expect(_entries(dir, 'afterFileEdit').length, 1);
    expect(_entries(dir, 'sessionStart').length, 1);
    removeCursorHooks(dir, 'abc123');
    expect(File(_hooksFile(dir)).readAsStringSync(), original);

    // Changed by the project while the worker ran: its change stays, laid out as the file was.
    expect(addCursorHooks(dir, _office, 'abc123'), isTrue);
    final edited = _readHooks(dir);
    ((edited['hooks'] as Map)['afterFileEdit'] as List).add({'command': './lint.sh'});
    File(_hooksFile(dir)).writeAsStringSync(const JsonEncoder.withIndent('\t').convert(edited));
    removeCursorHooks(dir, 'abc123');
    final after = File(_hooksFile(dir)).readAsStringSync();
    expect(jsonDecode(after), {
      'version': 1,
      'hooks': {
        'stop': [
          {'command': './notify.sh'},
        ],
        'afterFileEdit': [
          {'command': './format.sh'},
          {'command': './lint.sh'},
        ],
      },
    });
    expect(after, startsWith('{\n\t"version"'));
    expect(after.endsWith('\n'), isFalse);
    expect(File(p.join(dir, '.cursor', 'rules.md')).existsSync(), isTrue);
  });

  test('a hooks.json the office cannot read is left alone', () {
    final dir = _scratch().path;
    Directory(p.join(dir, '.cursor')).createSync();
    const jsonc = '{\n  // our hooks\n  "version": 1,\n  "hooks": {}\n}\n';
    File(_hooksFile(dir)).writeAsStringSync(jsonc);
    expect(addCursorHooks(dir, _office, 'abc123'), isFalse);
    removeCursorHooks(dir, 'abc123');
    expect(File(_hooksFile(dir)).readAsStringSync(), jsonc);
    expect(addCursorHooks(dir, _office, "bad'id"), isFalse);
  });

  test('helper forwards only the bounded root event fields to the authenticated bridge', () async {
    final bridge = await Bridge.start();
    try {
      final env = {
        'AGENT_OFFICE_HOOK_URL': bridge.url,
        'AGENT_OFFICE_HOOK_TOKEN': 'hook-token',
        'AGENT_OFFICE_WORKER_ID': 'worker-1',
      };
      final prompt = await hook(
        ['cursor', 'beforeSubmitPrompt', 'worker-1'],
        jsonEncode({
          'conversation_id': 'chat-1',
          'generation_id': 'gen-1',
          'prompt': 'fix it',
          'attachments': [
            {'file_path': '/private'},
          ],
          'user_email': 'me@example.com',
          'transcript_path': '/private',
        }),
        env,
      );
      // No decision of its own: Cursor's permission prompts are as they'd be without it.
      expect(prompt, '{}');
      expect(bridge.requests.single.url, '/hooks/cursor?worker=worker-1&event=beforeSubmitPrompt');
      expect(bridge.requests.single.authorization, 'Bearer hook-token');
      expect(jsonDecode(bridge.requests.single.body), {
        'conversation_id': 'chat-1',
        'hook_event_name': 'beforeSubmitPrompt',
        'prompt': 'fix it',
      });
      final tool = await hook(
        ['cursor', 'preToolUse', 'worker-1'],
        jsonEncode({
          'conversation_id': 'chat-1',
          'tool_name': 'Shell',
          'tool_use_id': 'tool-1',
          'tool_input': {'command': 'cat .env'},
          'agent_message': 'private',
        }),
        env,
      );
      expect(tool, '{}');
      expect(jsonDecode(bridge.requests.last.body), {
        'conversation_id': 'chat-1',
        'hook_event_name': 'preToolUse',
        'tool_name': 'Shell',
        'tool_use_id': 'tool-1',
      });
    } finally {
      await bridge.close();
    }
  });

  test("helper stays quiet for another worker, a person's own Cursor session, a subagent and unknown events", () async {
    final bridge = await Bridge.start();
    try {
      final base = {'AGENT_OFFICE_HOOK_URL': bridge.url, 'AGENT_OFFICE_HOOK_TOKEN': 'hook-token'};
      const payload = {'conversation_id': 'chat-1'};
      for (final (args, env, input) in [
        (['cursor', 'stop', 'worker-1'], {'AGENT_OFFICE_WORKER_ID': 'worker-2'}, payload),
        (['cursor', 'stop', 'worker-1'], <String, String>{}, payload),
        (
          ['cursor', 'stop', 'worker-1'],
          {'AGENT_OFFICE_WORKER_ID': 'worker-1'},
          {...payload, 'subagent_id': 'child-1'},
        ),
        (
          ['cursor', 'afterAgentResponse', 'worker-1'],
          {'AGENT_OFFICE_WORKER_ID': 'worker-1'},
          {...payload, 'text': 'private'},
        ),
      ]) {
        expect(await hook(args, jsonEncode(input), {...base, ...env}), '{}');
      }
      expect(bridge.requests, isEmpty);
    } finally {
      await bridge.close();
    }
  });

  test('a Cursor worker trusts its folder, resumes its chat and takes its hooks out when it ends', () {
    final dir = _scratch().path;
    const cursor = CursorAdapter();
    final setup = cursor.prepare(ProviderFloor(dataDir: dir, office: _office));
    final h = handleFor(AgentProvider.cursor, model: 'gpt-5');
    final fresh = cursor.launch(
      LaunchInput(h: h, args: ['--force', '--yolo', '--mode', 'plan'], prompt: 'fix it', cwd: dir, setup: setup),
    );
    // --force and --yolo are never passed.
    expect(fresh.args, ['--mode', 'plan', '--trust', '--model', 'gpt-5', '--', 'fix it']);
    expect(_entries(dir, 'stop').length, 1);
    final resumed = cursor.launch(LaunchInput(h: h, args: [], resumeSessionId: 'chat-1', cwd: dir, setup: setup));
    expect(resumed.args, ['--trust', '--resume=chat-1']);
    cursor.exited(h, dir);
    expect(File(_hooksFile(dir)).existsSync(), isFalse);
  });

  test('a chat started over inside the terminal is a new session from its first prompt', () {
    final h = handleFor(AgentProvider.cursor, sessionId: 'chat-1');
    final handle = const CursorAdapter().hook!.handle;
    expect(handle(h, 'sessionStart', {'conversation_id': 'chat-1'}), isTrue);
    expect(h.info.status, WorkerStatus.idle);
    expect(handle(h, 'beforeSubmitPrompt', {'conversation_id': 'chat-2', 'prompt': 'new thing'}), isTrue);
    expect(h.info.sessionId, 'chat-2');
    expect(h.info.status, WorkerStatus.working);
    handle(h, 'stop', {'conversation_id': 'chat-2'});
    expect(h.info.status, WorkerStatus.done);
  });
}
