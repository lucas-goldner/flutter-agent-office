import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/codex.dart';
import 'package:agent_office_server/src/hook.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A local stand-in for the office's hook bridge, recording what arrives.
class Bridge {
  Bridge._(this.server);

  final HttpServer server;
  final requests = <({String url, String? authorization, String? contentType, String body})>[];

  static Future<Bridge> start({int port = 0}) async {
    final bridge = Bridge._(await HttpServer.bind('127.0.0.1', port));
    bridge.server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      bridge.requests.add((
        url: req.uri.toString(),
        authorization: req.headers.value('authorization'),
        contentType: req.headers.value('content-type'),
        body: body,
      ));
      req.response.statusCode = 200;
      await req.response.close();
    });
    return bridge;
  }

  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);
}

/// Runs the hook helper in-process with [stdin] as its input; returns what it printed.
Future<String> hook(List<String> args, String stdin, Map<String, String> env) async {
  final out = StringBuffer();
  final controller = StreamController<List<int>>();
  final done = controller.stream.listen((b) => out.write(utf8.decode(b))).asFuture<void>();
  final sink = IOSink(controller);
  expect(await runHook(args, input: Stream.value(utf8.encode(stdin)), environment: env, output: sink), 0);
  await sink.close();
  await done;
  return out.toString();
}

void main() {
  test('normalizes bounded root Codex hook payloads and passes only the metric reader path', () {
    expect(
      normalizeCodexHook('SessionStart', {
        'session_id': 'thread-1',
        'source': 'startup',
        'transcript_path': '/private/transcript.jsonl',
        'turn_id': 'turn-1',
      })?.toJson(),
      {
        'sessionId': 'thread-1',
        'event': 'SessionStart',
        'source': 'startup',
        'turnId': 'turn-1',
        'transcriptPath': '/private/transcript.jsonl',
      },
    );
    expect(
      normalizeCodexHook('UserPromptSubmit', {
        'session_id': 'thread-1',
        'prompt': '  fix the login  ',
        'turn_id': 'turn-2',
        'model': 'secret-model',
      })?.toJson(),
      {'sessionId': 'thread-1', 'event': 'UserPromptSubmit', 'prompt': 'fix the login', 'turnId': 'turn-2'},
    );
    expect(
      normalizeCodexHook('PermissionRequest', {
        'session_id': 'thread-1',
        'tool_name': 'Bash',
        'tool_use_id': 'tool-1',
        'tool_input': {'command': 'secret'},
      })?.toJson(),
      {'sessionId': 'thread-1', 'event': 'PermissionRequest', 'tool': 'Bash', 'toolUseId': 'tool-1'},
    );
  });

  test('rejects unknown, malformed, empty, oversized, and child-scoped events', () {
    expect(validateCodexHook('Unknown', {'session_id': 'x'}), false);
    expect(validateCodexHook('Stop', null), false);
    expect(validateCodexHook('Stop', {'session_id': ''}), false);
    expect(validateCodexHook('Stop', {'session_id': 'x' * 161}), false);
    expect(validateCodexHook('Stop', {'session_id': 'x', 'agent_id': 'child-1'}), false);
    expect(validateCodexHook('Stop', {'session_id': 'x', 'agent_type': 'explorer'}), false);
    expect(validateCodexHook('Stop', {'session_id': 'x', 'agent_id': 'c' * 161}), false);
  });

  test('generates one stable CLI hook override per supported event', () {
    final args = codexHookArgs(['/tmp/office data/agent-office']);
    expect(args.length, codexHookEvents.length * 2);
    for (var i = 0; i < codexHookEvents.length; i++) {
      expect(args[i * 2], '-c');
      expect(args[i * 2 + 1], matches(RegExp('^hooks\\.${codexHookEvents[i]}=\\[\\{hooks=')));
      expect(args[i * 2 + 1], contains('type="command"'));
      expect(args[i * 2 + 1], contains('timeout=3'));
      // The office's own executable, shell-quoted inside a TOML string: no Node, no helper file.
      expect(
        args[i * 2 + 1],
        contains("command=\"'/tmp/office data/agent-office' 'hook' 'codex' '${codexHookEvents[i]}'\""),
      );
    }
  });

  test('runs the office itself as the hook: the compiled binary, or the entry point under dart run', () {
    final exe = officeCommand();
    expect(exe.first, Platform.resolvedExecutable);
    // Tests run on the Dart VM, so this is `dart run <server>/bin/agent_office.dart`.
    expect(exe.sublist(1, 2), ['run']);
    expect(exe.last, p.join(p.normalize(p.absolute('.')), 'bin', 'agent_office.dart'));
    expect(codexHookArgs().first, '-c');
  });

  test('the helper bounds its input and needs the bridge environment', () async {
    final bridge = await Bridge.start();
    try {
      final env = {
        'AGENT_OFFICE_HOOK_URL': bridge.url,
        'AGENT_OFFICE_HOOK_TOKEN': 'hook-token',
        'AGENT_OFFICE_WORKER_ID': 'worker-1',
      };
      final ok = jsonEncode({'session_id': 'thread-1'});
      expect(await hook(['codex', 'Stop'], jsonEncode({'session_id': 'thread-1', 'x': 'y' * (64 * 1024)}), env), '');
      expect(await hook(['codex', 'Unknown'], ok, env), '');
      expect(await hook(['codex', 'Stop'], 'not json', env), '');
      expect(await hook(['codex', 'Stop'], jsonEncode({'session_id': 'thread-1', 'agent_id': 'child'}), env), '');
      expect(await hook(['codex', 'Stop'], ok, {...env}..remove('AGENT_OFFICE_HOOK_TOKEN')), '');
      expect(bridge.requests, isEmpty);
      expect(await hook(['codex', 'Stop'], ok, env), '{}');
      expect(bridge.requests.length, 1);
    } finally {
      await bridge.close();
    }
  });

  test('helper forwards only the bounded root event fields to the authenticated bridge', () async {
    final bridge = await Bridge.start();
    try {
      final stdout = await hook(
        ['codex', 'UserPromptSubmit'],
        jsonEncode({
          'session_id': 'thread-1',
          'prompt': 'fix it',
          'turn_id': 'turn-1',
          'transcript_path': '/private/transcript.jsonl',
          'model': 'private-model',
          'tool_input': {'command': 'private'},
          'hook_event_name': 'forged',
        }),
        {
          'PATH': Platform.environment['PATH'] ?? '',
          'AGENT_OFFICE_HOOK_URL': bridge.url,
          'AGENT_OFFICE_HOOK_TOKEN': 'hook-token',
          'AGENT_OFFICE_WORKER_ID': 'worker-1',
        },
      );
      expect(stdout, '{}');
      final received = bridge.requests.single;
      expect(received.authorization, 'Bearer hook-token');
      expect(received.url, '/hooks/codex?worker=worker-1&event=UserPromptSubmit');
      expect(jsonDecode(received.body), {
        'session_id': 'thread-1',
        'hook_event_name': 'UserPromptSubmit',
        'prompt': 'fix it',
        'turn_id': 'turn-1',
        'transcript_path': '/private/transcript.jsonl',
      });
    } finally {
      await bridge.close();
    }
  });

  group('Claude hooks', () {
    test('try curl first and fall back to the office executable, silently', () {
      final command = claudeHookCommand('Stop', office: ['/opt/agent office/agent-office']);
      expect(
        command,
        'if [ -z "\$AGENT_OFFICE_WORKER_ID" ] || [ -z "\$AGENT_OFFICE_HOOK_URL" ]; then exit 0; fi; '
        'if command -v curl >/dev/null 2>&1; then curl -sS -m 3 --retry 5 --retry-delay 1 --retry-connrefused -X POST '
        '-H "Authorization: Bearer \$AGENT_OFFICE_HOOK_TOKEN" -H "Content-Type: application/json" --data-binary @- '
        '"\$AGENT_OFFICE_HOOK_URL/hooks/claude?worker=\$AGENT_OFFICE_WORKER_ID&event=Stop" >/dev/null 2>&1; '
        "else '/opt/agent office/agent-office' 'hook' 'claude' 'Stop' >/dev/null 2>&1; fi; true",
      );
      expect(command, isNot(contains('node')));
    });

    test('the fallback posts the payload as it came, like curl --data-binary', () async {
      final bridge = await Bridge.start();
      try {
        const payload = '{"session_id":"abc","transcript_path":"/x.jsonl","prompt":"héllo"}';
        final out = await hook(
          ['claude', 'UserPromptSubmit'],
          payload,
          {'AGENT_OFFICE_HOOK_URL': bridge.url, 'AGENT_OFFICE_HOOK_TOKEN': 'tok', 'AGENT_OFFICE_WORKER_ID': 'w-1'},
        );
        expect(out, '');
        final r = bridge.requests.single;
        expect(r.url, '/hooks/claude?worker=w-1&event=UserPromptSubmit');
        expect(r.authorization, 'Bearer tok');
        expect(r.contentType, 'application/json');
        expect(r.body, payload);
      } finally {
        await bridge.close();
      }
    });

    test('the fallback retries while the office is restarting', () async {
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();
      final env = {
        'AGENT_OFFICE_HOOK_URL': 'http://127.0.0.1:$port',
        'AGENT_OFFICE_HOOK_TOKEN': 'tok',
        'AGENT_OFFICE_WORKER_ID': 'w-1',
      };
      final running = hook(['claude', 'Stop'], '{}', env);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final bridge = await Bridge.start(port: port);
      try {
        await running;
        expect(bridge.requests.single.url, '/hooks/claude?worker=w-1&event=Stop');
      } finally {
        await bridge.close();
      }
    });
  });
}
