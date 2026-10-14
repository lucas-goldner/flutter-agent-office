// A fake DeepSeek Harness ACP agent for test/dsh_test.dart (upstream's tests/dsh.test.ts fakeAgent):
// it speaks ACP v1 over stdio the way `dsh --profile acp` does. Sessions survive the process (in
// DSH_FAKE_SESSIONS): that is how a restart resumes one. Compiled once by the tests.
import 'dart:convert';
import 'dart:io';

void main(List<String> argv) {
  final env = Platform.environment;
  void out(Object m) => stdout.write('${jsonEncode(m)}\n');
  final log = env['DSH_FAKE_LOG'];
  final sessionsFile = env['DSH_FAKE_SESSIONS'];
  // A fake agent never takes the suite down with it: a bad log path is not a protocol error.
  void append(String? file, String text) {
    try {
      if (file != null && file.isNotEmpty) File(file).writeAsStringSync(text, mode: FileMode.append);
    } catch (_) {}
  }

  append(
    log,
    '${jsonEncode({'argv': argv, 'cwd': Directory.current.resolveSymbolicLinksSync(), 'profile': ?env['AGENT_OFFICE_DSH_PROFILE'], 'workerId': ?env['AGENT_OFFICE_WORKER_ID']})}\n',
  );

  List<String> readSessions() {
    if (sessionsFile == null || !File(sessionsFile).existsSync()) return [];
    try {
      return File(sessionsFile).readAsStringSync().split('\n').where((l) => l.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  void remember(String id) => append(sessionsFile, '$id\n');

  var modelValue = '["fake-provider","fake-flash"]';
  var effort = 'high';
  const modelValues = ['["fake-provider","fake-flash"]', '["fake-provider","fake-pro"]'];
  const effortValues = ['off', 'low', 'high', 'max'];
  // The shape dsh 0.1.7-rc.2 really sends: route tuples, grouped by provider.
  List<Object> configOptions() => [
    {
      'id': 'model',
      'name': 'Model',
      'category': 'model',
      'type': 'select',
      'currentValue': modelValue,
      'options': [
        {
          'group': 'fake-provider',
          'name': 'Fake',
          'options': [
            {'value': modelValues[0], 'name': 'fake-flash'},
            {'value': modelValues[1], 'name': 'Fake Pro'},
          ],
        },
      ],
    },
    {
      'id': 'reasoning_effort',
      'name': 'Reasoning effort',
      'category': 'thought_level',
      'type': 'select',
      'currentValue': effort,
      'options': [
        for (final v in effortValues) {'value': v, 'name': v},
      ],
    },
  ];

  var agentRequestId = 500;
  Object? pendingPrompt;
  ({int id, Object? promptId})? pendingPermission;

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final text = line.trim();
    if (text.isEmpty) return;
    Map msg;
    try {
      msg = jsonDecode(text) as Map;
    } catch (_) {
      return;
    }
    final method = msg['method'];
    final params = msg['params'] is Map ? msg['params'] as Map : const {};

    // The client answering something we asked (a permission request).
    if (method == null && msg['id'] != null) {
      final permission = pendingPermission;
      if (permission == null || msg['id'] != permission.id) return;
      final answer = env['DSH_FAKE_ANSWER'];
      append(answer, '${jsonEncode(msg['result'])}\n');
      final result = msg['result'];
      final cancelled = result is Map && result['outcome'] is Map && result['outcome']['outcome'] == 'cancelled';
      pendingPermission = null;
      out({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'sess-1',
          'update': {
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 't1',
            'title': 'Run tests',
            'status': cancelled ? 'failed' : 'completed',
          },
        },
      });
      out({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'sess-1',
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'ng'},
          },
        },
      });
      out({
        'jsonrpc': '2.0',
        'id': permission.promptId,
        'result': {'stopReason': cancelled ? 'cancelled' : 'end_turn'},
      });
      pendingPrompt = null;
      return;
    }

    final id = msg['id'];
    switch (method) {
      case 'initialize':
        out({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': 1,
            'agentCapabilities': {
              'sessionCapabilities': {'list': {}, 'resume': {}, 'close': {}},
            },
            'authMethods': [],
            'agentInfo': {'name': 'fake-dsh', 'version': '0'},
          },
        });
      case 'session/new':
        final sid = 'sess-${readSessions().length + 1}';
        remember(sid);
        out({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'sessionId': sid, 'configOptions': configOptions()},
        });
      case 'session/resume':
        final known = readSessions().contains(params['sessionId']);
        if (env['DSH_FAKE_RESUME_FAILS'] == '1' || !known) {
          out({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'unknown session'},
          });
          return;
        }
        append(log, '${jsonEncode({'resumed': params['sessionId']})}\n');
        out({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'configOptions': configOptions()},
        });
      case 'session/set_config_option':
        final configId = params['configId'], value = params['value'];
        if (configId == 'model' && modelValues.contains(value)) {
          modelValue = value as String;
        } else if (configId == 'reasoning_effort' && effortValues.contains(value)) {
          effort = value as String;
        } else {
          out({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'unknown $configId'},
          });
          return;
        }
        out({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'configOptions': configOptions()},
        });
      case 'session/close':
        out({'jsonrpc': '2.0', 'id': id, 'result': {}});
        stdout.flush().then((_) => Future<void>.delayed(const Duration(milliseconds: 10))).then((_) => exit(0));
      case 'session/cancel':
        if (pendingPrompt != null) {
          out({
            'jsonrpc': '2.0',
            'id': pendingPrompt,
            'result': {'stopReason': 'cancelled'},
          });
          pendingPrompt = null;
        }
      case 'session/prompt':
        final sessionId = params['sessionId'];
        pendingPrompt = id;
        void update(Map<String, Object> u) => out({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {'sessionId': sessionId, 'update': u},
        });
        update({
          'sessionUpdate': 'agent_message_chunk',
          'content': {'type': 'text', 'text': 'po'},
        });
        update({
          'sessionUpdate': 'agent_thought_chunk',
          'content': {'type': 'text', 'text': 'weighing it up'},
        });
        update({
          'sessionUpdate': 'tool_call',
          'toolCallId': 't1',
          'title': 'Run tests',
          'kind': 'execute',
          'status': 'pending',
          'rawInput': {'command': 'npm test'},
        });
        update({
          'sessionUpdate': 'usage_update',
          'used': 1234,
          'size': 200000,
          if (env['DSH_FAKE_NO_COST'] != '1') 'cost': {'amount': 0.02, 'currency': 'USD'},
        });
        if (env['DSH_FAKE_NO_SETTLE'] == '1') return;
        if (env['DSH_FAKE_NO_PERMISSION'] == '1') {
          update({
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'ng'},
          });
          out({
            'jsonrpc': '2.0',
            'id': id,
            'result': {'stopReason': 'end_turn'},
          });
          pendingPrompt = null;
          return;
        }
        final permission = (id: agentRequestId++, promptId: id);
        pendingPermission = permission;
        final options = env['DSH_FAKE_NO_REJECT'] == '1'
            ? [
                {'optionId': 'allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
              ]
            : env['DSH_FAKE_ALWAYS_ONLY'] == '1'
            ? [
                {'optionId': 'allow-always', 'name': 'Always allow', 'kind': 'allow_always'},
                {'optionId': 'reject-once', 'name': 'Reject', 'kind': 'reject_once'},
              ]
            : [
                {'optionId': 'allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
                {'optionId': 'reject-once', 'name': 'Reject', 'kind': 'reject_once'},
              ];
        out({
          'jsonrpc': '2.0',
          'id': permission.id,
          'method': 'session/request_permission',
          'params': {
            'sessionId': sessionId,
            'toolCall': {'toolCallId': 't1', 'title': 'Run tests', 'kind': 'execute', 'status': 'pending'},
            'options': options,
          },
        });
    }
  }, onDone: () => exit(0));
}
