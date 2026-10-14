// Upstream's tests/pi.test.ts: the command line, the bridge's bounds, the extension (loaded in a JS
// runtime when the machine has one) and the adapter.
import 'dart:io';

import 'package:agent_office_server/src/pi.dart';
import 'package:agent_office_server/src/providers/providers.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_handle.dart';

String? _jsRuntime() {
  for (final name in ['node', 'bun']) {
    try {
      final r = Process.runSync('which', [name]);
      if (r.exitCode == 0) return '${r.stdout}'.trim();
    } catch (_) {}
  }
  return null;
}

final _runtime = _jsRuntime();

void main() {
  test('Pi launch uses interactive mode, an isolated session, and safe prompt arguments', () {
    final args = piArgs(
      [
        '--provider', 'openai', '--model', 'old', '--thinking', 'low', '--mode', 'rpc', '-p', '--continue', //
        '--session', 'other', '--session-dir', '/shared', '-e', '/user-extension.mjs',
      ],
      extension: '/office-extension.mjs',
      sessionDir: '/worker-session',
      sessionId: 'worker-session-id',
      model: 'openai/gpt-4.1',
      effort: AgentEffort.high,
      prompt: '- fix login',
    );
    expect(args, [
      '-e', '/user-extension.mjs', '--session-dir', '/worker-session', '--extension', '/office-extension.mjs', //
      '--session-id', 'worker-session-id', '--model', 'openai/gpt-4.1', '--thinking', 'high', '--', '- fix login',
    ]);
    expect(
      piArgs(
        ['--model', 'sonnet', '--thinking', 'off', '--no-extensions'],
        extension: 'office.mjs',
        sessionDir: 'worker',
      ),
      [
        '--model',
        'sonnet',
        '--thinking',
        'off',
        '--no-extensions',
        '--session-dir',
        'worker',
        '--extension',
        'office.mjs', //
      ],
    );
  });

  test('Pi bridge bounds fields and drops assistant text, tool input, and credentials', () {
    expect(
      normalizePiHook({
        'type': 'tool',
        'status': 'working',
        'sessionId': 'root',
        'tool': 'bash',
        'args': {'command': 'secret'},
        'apiKey': 'secret',
        'assistantMessage': 'secret',
      })?.toJson(),
      {'type': 'tool', 'sessionId': 'root', 'status': 'working', 'tool': 'bash'},
    );
    for (final value in <Object?>[
      null,
      <Object>[],
      <String, Object>{},
      {'type': 'unknown', 'status': 'working', 'sessionId': 'root'},
      {'type': 'session', 'status': 'working', 'sessionId': 'x' * 161},
      {'type': 'session', 'status': 'bad', 'sessionId': 'root'},
      {'type': 'prompt', 'status': 'working', 'sessionId': 'root', 'prompt': 'x' * 20001},
    ]) {
      expect(normalizePiHook(value), isNull, reason: '$value');
    }
    expect(isValidPiModel('sonnet:high'), isTrue);
    expect(isValidPiModel('openai/gpt-4.1'), isTrue);
    expect(isValidPiModel('--print'), isFalse);
    expect(isValidPiModel('bad\u200bmodel'), isFalse);
  });

  test('what reaches the Pi command line from a hook or the hire dialog is only ever plain values', () {
    // A session id goes back to Pi as --session-id on resume: only what Pi itself takes.
    for (final sessionId in ['a b', 'x&calc', 'id|more', '../up', 'flag\u0000']) {
      expect(
        normalizePiHook({'type': 'session', 'status': 'starting', 'sessionId': sessionId}),
        isNull,
        reason: sessionId,
      );
    }
    expect(
      normalizePiHook({'type': 'session', 'status': 'starting', 'sessionId': '0192f-a_b.c'})?.sessionId,
      '0192f-a_b.c',
    );
    // A Windows .cmd launcher runs through cmd.exe: none of its metacharacters get into a model.
    for (final model in ['a&b', 'a|b', 'a^b', '%PATH%', 'a<b', 'a>b', 'a"b', '-m']) {
      expect(isValidPiModel(model), isFalse, reason: model);
    }
    // Pi reads a leading '@' as a file to include: a prompt that starts with one stays text.
    final args = piArgs([], extension: 'x.mjs', sessionDir: 'd', prompt: '@README.md fix the typo');
    expect(args.sublist(args.length - 2), ['--', ' @README.md fix the typo']);
  });

  test(
    'Pi extension reports ordered lifecycle events, waits for actual settlement, and never interrupts the agent',
    () async {
      final dir = Directory.systemTemp.createTempSync('agent-office-pi-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final extension = writePiExtension(dir.path);
      if (!Platform.isWindows) expect(File(extension).statSync().mode & 0x1ff, 0x180); // 0600
      final harness = File(p.join(dir.path, 'harness.mjs'))..writeAsStringSync(_harness);
      final r = await Process.run(_runtime!, [harness.path, Uri.file(extension).toString()]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect('${r.stdout}'.trim(), 'ok');
    },
    skip: _runtime == null ? 'no JavaScript runtime' : null,
  );

  test('a Pi worker runs in its own session folder, and its hooks drive it through its turn', () {
    final dir = Directory.systemTemp.createTempSync('agent-office-pi-');
    addTearDown(() => dir.deleteSync(recursive: true));
    const pi = PiAdapter();
    final setup = pi.prepare(ProviderFloor(dataDir: dir.path, office: const ['/opt/agent-office'])) as PiSetup;
    expect(File(setup.extension).readAsStringSync(), contains('agent_settled'));
    final h = handleFor(AgentProvider.pi, model: 'openai/gpt-4.1', effort: AgentEffort.high);
    final plan = pi.launch(LaunchInput(h: h, args: [], prompt: '- fix login', cwd: dir.path, setup: setup));
    final sessionDir = p.join(dir.path, 'pi-sessions', h.info.id);
    expect(Directory(sessionDir).existsSync(), isTrue);
    expect(plan.args, contains(sessionDir));
    expect(plan.args.sublist(plan.args.length - 6), [
      '--model',
      'openai/gpt-4.1',
      '--thinking',
      'high',
      '--',
      '- fix login',
    ]);
    expect(plan.rotateToken, isTrue);

    final handle = pi.hook!.handle;
    bool hook(String type, String status, [Map<String, Object> extra = const {}]) =>
        handle(h, '', {'type': type, 'status': status, 'sessionId': 'pi-root', ...extra});
    h.bootBlocked = true;
    expect(hook('session', 'starting'), isTrue);
    expect(h.bootBlocked, isFalse);
    expect(h.info.status, WorkerStatus.idle);
    expect(h.info.sessionId, 'pi-root');
    hook('prompt', 'working', {'prompt': 'Fix login'});
    expect(h.info.status, WorkerStatus.working);
    hook('question', 'needs_input');
    expect(h.info.status, WorkerStatus.needsInput);
    hook('session', 'done');
    expect(h.info.status, WorkerStatus.done);
    expect(handle(h, '', {'type': 'tool', 'status': 'working', 'sessionId': 'other-root'}), isFalse);
    // A resumed session starts the desk idle, whatever it was doing.
    hook('session', 'starting');
    expect(h.info.status, WorkerStatus.idle);

    final resumed = pi.launch(LaunchInput(h: h, args: [], resumeSessionId: 'pi-root', cwd: dir.path, setup: setup));
    expect(resumed.args, containsAllInOrder(['--session-id', 'pi-root']));
  });
}

/// tests/pi.test.ts's two extension cases, as plain JavaScript.
const _harness = r'''
import assert from 'node:assert/strict';

const [extensionUrl] = process.argv.slice(2);
process.env.AGENT_OFFICE_WORKER_ID = 'worker';
process.env.AGENT_OFFICE_HOOK_TOKEN = 'worker-token';
process.env.AGENT_OFFICE_HOOK_URL = 'http://127.0.0.1:1234';
const requests = [];
let failing = false;
globalThis.fetch = async (url, options) => {
  if (failing) throw new Error('office unavailable');
  requests.push({ url: String(url), token: options.headers.Authorization, body: JSON.parse(options.body) });
};
const install = (await import(extensionUrl)).default;

const handlers = new Map();
install({ on: (name, fn) => handlers.set(name, fn) });
const ctx = { sessionManager: { getSessionId: () => 'session-1' }, isIdle: () => false };
const fire = (name, event = {}) => handlers.get(name)?.(event, ctx);
await fire('session_start');
await fire('before_agent_start', { prompt: 'Fix login' });
await fire('tool_execution_start', { toolName: 'bash', args: { command: 'secret' } });
await fire('tool_execution_end', { toolName: 'bash', isError: true });
await fire('ui_prompt_start');
await fire('ui_prompt_end');
const before = requests.length;
await fire('agent_end');
assert.equal(requests.length, before, 'intermediate agent_end must not complete a queued task');
await fire('agent_settled');
assert.deepEqual(requests.map((r) => r.body.status), ['starting', 'working', 'working', 'working', 'needs_input', 'working', 'done']);
assert.ok(requests.every((r) => r.url === 'http://127.0.0.1:1234/hooks/pi?worker=worker' && r.token === 'Bearer worker-token'));
assert.ok(requests.every((r) => !('args' in r.body)));
await fire('session_shutdown');

// Connectivity failures never interrupt the agent.
failing = true;
const again = new Map();
install({ on: (name, fn) => again.set(name, fn) });
await again.get('session_start')?.({}, { sessionManager: { getSessionId: () => 'root' } });
await again.get('session_shutdown')?.({}, {});
console.log('ok');
''';
