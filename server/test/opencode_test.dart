import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/opencode.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The plugin is JavaScript that OpenCode's own runtime loads, so its behaviour is checked by
/// loading it in a JS runtime too (Node or Bun, whichever the machine has; skipped without one).
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

/// Runs [scenario] from [_harness] against a freshly written plugin; fails the test on any assertion.
Future<void> runScenario(String scenario, String prefix) async {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = writeOpenCodePlugin(dir.path);
  final harness = File(p.join(dir.path, 'harness.mjs'))..writeAsStringSync(_harness);
  final r = await Process.run(_runtime!, [harness.path, openCodePluginSpecifier(file), scenario]);
  expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  expect('${r.stdout}'.trim(), 'ok');
}

void main() {
  test('merges the inline OpenCode config and preserves user plugins', () {
    const plugin = 'file:///tmp/agent-office-opencode.mjs';
    final merged =
        jsonDecode(
              mergeOpenCodeConfigContent(
                jsonEncode({
                  'model': 'x/y',
                  'plugin': ['one'],
                }),
                plugin,
              ),
            )
            as Map;
    expect(merged['model'], 'x/y');
    expect(merged['plugin'], ['one', plugin]);
  });

  test('does not duplicate the generated plugin in inline config', () {
    const plugin = 'file:///tmp/agent-office-opencode.mjs';
    final merged =
        jsonDecode(
              mergeOpenCodeConfigContent(
                jsonEncode({
                  'plugin': [plugin],
                }),
                plugin,
              ),
            )
            as Map;
    expect(merged['plugin'], [plugin]);
  });

  test('rejects malformed inline OpenCode config instead of dropping user settings', () {
    expect(
      () => mergeOpenCodeConfigContent('{model:', 'file:///tmp/agent-office-opencode.mjs'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('OPENCODE_CONFIG_CONTENT'))),
    );
  });

  test('writes the plugin into the data dir, readable only by the office', () {
    // Not in the TS suite, which checked the file by importing it.
    final dir = Directory.systemTemp.createTempSync('agent-office-opencode-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = writeOpenCodePlugin(p.join(dir.path, 'data'));
    expect(file, p.join(dir.path, 'data', 'agent-office-opencode.mjs'));
    expect(File(file).readAsStringSync(), openCodePluginSource);
    if (!Platform.isWindows) expect(File(file).statSync().mode & 0x1ff, 0x180); // 0600
    expect(openCodePluginSpecifier(file), Uri.file(file).toString());
    expect(openCodePluginSpecifier(file), startsWith('file:///'));
  });

  test(
    'writes a loadable plugin module that forwards root events and excludes subagents',
    () => runScenario('events', 'agent-office-opencode-'),
    skip: _runtime == null ? 'no JavaScript runtime' : null,
  );

  test(
    'hydrates persisted OpenCode root and child usage without blocking plugin startup',
    () => runScenario('hydrate', 'agent-office-opencode-hydrate-'),
    skip: _runtime == null ? 'no JavaScript runtime' : null,
  );

  test(
    'marks live OpenCode usage incomplete when hydration fails',
    () => runScenario('partial', 'agent-office-opencode-partial-'),
    skip: _runtime == null ? 'no JavaScript runtime' : null,
  );
}

/// The three plugin cases of tests/opencode.test.ts, as plain JavaScript.
const _harness = r'''
import assert from 'node:assert/strict';

const [pluginUrl, scenario] = process.argv.slice(2);
const sent = [];
globalThis.fetch = async (_url, init) => {
  sent.push(JSON.parse(String(init?.body)));
  return new Response(null, { status: 200 });
};
process.env.AGENT_OFFICE_HOOK_URL = 'http://127.0.0.1:1';
process.env.AGENT_OFFICE_HOOK_TOKEN = 'token';
process.env.AGENT_OFFICE_WORKER_ID = 'worker';

const scenarios = {
  async events() {
    process.env.AGENT_OFFICE_SESSION_ID = 'ses_existing';
    const mod = await import(`${pluginUrl}?test=${Date.now()}`);
    const hooks = await mod.default({});
    await hooks.event({ event: { type: 'session.status', properties: { sessionID: 'ses_existing', status: { type: 'busy' } } } });
    await hooks.event({ event: { type: 'session.created', properties: { info: { id: 'ses_root' } } } });
    await hooks.event({ event: { type: 'session.created', properties: { info: { id: 'ses_child', parentID: 'ses_root' } } } });
    await hooks.event({ event: { type: 'session.status', properties: { sessionID: 'ses_child', status: { type: 'busy' } } } });
    await hooks['chat.message']({ sessionID: 'ses_root' }, { parts: [{ type: 'text', text: 'fix the thing' }] });
    await hooks.event({ event: { type: 'session.status', properties: { sessionID: 'ses_root', status: { type: 'busy' } } } });
    assert.deepEqual(sent, [
      { type: 'session', sessionId: 'ses_existing', status: 'working' },
      { type: 'session', sessionId: 'ses_root', status: 'starting' },
      { type: 'prompt', sessionId: 'ses_root', status: 'working', prompt: 'fix the thing' },
      { type: 'session', sessionId: 'ses_root', status: 'working' },
    ]);

    sent.length = 0;
    await hooks.event({ event: { type: 'message.updated', properties: { info: {
      id: 'msg-root', sessionID: 'ses_root', role: 'assistant', cost: 0.12,
      tokens: { input: 10, output: 4, reasoning: 2, cache: { read: 3, write: 1 } },
    } } } });
    await hooks.event({ event: { type: 'message.updated', properties: { sessionID: 'ses_root', info: {
      id: 'msg-root', sessionID: 'ses_root', role: 'assistant', cost: 0.2,
      tokens: { input: 11, output: 7, reasoning: 3, cache: { read: 4, write: 2 } },
    } } } });
    await hooks.event({ event: { type: 'message.updated', properties: { sessionID: 'ses_child', info: {
      id: 'msg-child', sessionID: 'ses_child', role: 'assistant', cost: 0.05,
      tokens: { input: 5, output: 2, reasoning: 0, cache: { read: 1, write: 0 } },
    } } } });
    await hooks.event({ event: { type: 'session.created', properties: { info: { id: 'ses_unrelated', parentID: 'another_root' } } } });
    await hooks.event({ event: { type: 'message.updated', properties: { sessionID: 'ses_unrelated', info: {
      id: 'msg-unrelated', sessionID: 'ses_unrelated', role: 'assistant', cost: 99,
      tokens: { input: 100, output: 100, reasoning: 100, cache: { read: 100, write: 100 } },
    } } } });
    assert.deepEqual(sent, [
      { type: 'usage', sessionId: 'ses_root', usage: { input: 10, output: 4, reasoning: 2, cacheRead: 3, cacheWrite: 1, cost: 0.12, calls: 1, costKnown: true } },
      { type: 'usage', sessionId: 'ses_root', usage: { input: 11, output: 7, reasoning: 3, cacheRead: 4, cacheWrite: 2, cost: 0.2, calls: 1, costKnown: true } },
      { type: 'usage', sessionId: 'ses_root', usage: { input: 16, output: 9, reasoning: 3, cacheRead: 5, cacheWrite: 2, cost: 0.25, calls: 2, costKnown: true } },
    ]);

    // Selecting an existing root conversation emits no session.created event. Verify it through
    // the SDK before adopting it, and serialize that lookup with subsequent busy/idle events.
    const selected = await mod.default({ client: { session: { get: async ({ path }) => {
      await new Promise((resolve) => setTimeout(resolve, 10));
      return { data: { id: path.id, ...(path.id === 'child' ? { parentID: 'parent' } : {}) } };
    } } } });
    sent.length = 0;
    await Promise.all([
      selected['chat.message']({ sessionID: 'saved' }, { parts: [{ type: 'text', text: 'continue here' }] }),
      selected.event({ event: { type: 'session.status', properties: { sessionID: 'saved', status: { type: 'idle' } } } }),
    ]);
    assert.deepEqual(sent, [
      { type: 'session', sessionId: 'saved', status: 'starting' },
      { type: 'prompt', sessionId: 'saved', status: 'working', prompt: 'continue here' },
      { type: 'session', sessionId: 'saved', status: 'done' },
    ]);
    await selected['chat.message']({ sessionID: 'child' }, { parts: [{ type: 'text', text: 'child task' }] });
    assert.equal(sent.length, 3, 'a child prompt must not take over the worker');

    // State belongs to the plugin instance, even when OpenCode caches the module itself.
    await hooks.event({ event: { type: 'session.status', properties: { sessionID: 'ses_root', status: { type: 'idle' } } } });
    assert.deepEqual(sent.at(-1), { type: 'session', sessionId: 'ses_root', status: 'done' });

    sent.length = 0;
    const event = (type, properties) => selected.event({ event: { type, properties: { sessionID: 'saved', ...properties } } });
    await event('permission.asked', { id: 'permission-1', permission: 'edit' });
    await event('question.asked', { id: 'question-1', questions: [{ question: 'Which file?' }] });
    await event('permission.replied', { requestID: 'permission-1', reply: 'once' });
    assert.equal(sent.at(-1).status, 'needs_input');
    await event('question.replied', { requestID: 'question-1', answers: [['one.ts']] });
    assert.equal(sent.at(-1).status, 'working');
    await event('session.error', { error: { name: 'APIError', data: { message: 'Unavailable' } } });
    assert.deepEqual(sent.at(-1), { type: 'error', sessionId: 'saved', status: 'needs_input', detail: 'Unavailable' });
  },

  async hydrate() {
    process.env.AGENT_OFFICE_SESSION_ID = 'hydrate-root';
    const session = {
      children: async function ({ path: value }) {
        assert.equal(this, session);
        return { data: value.id === 'hydrate-root' ? [{ id: 'hydrate-child' }] : [] };
      },
      messages: async function ({ path: value }) {
        assert.equal(this, session);
        return {
          data: value.id === 'hydrate-root'
            ? [{ info: {
              id: 'hydrate-root-message', sessionID: 'hydrate-root', role: 'assistant', cost: 0.4,
              tokens: { input: 8, output: 3, reasoning: 1, cache: { read: 2, write: 0 } },
            } }]
            : [{ info: {
              id: 'hydrate-child-message', sessionID: 'hydrate-child', role: 'assistant', cost: 0.1,
              tokens: { input: 4, output: 2, reasoning: 0, cache: { read: 1, write: 1 } },
            } }],
        };
      },
    };
    const mod = await import(`${pluginUrl}?hydrate=${Date.now()}`);
    await mod.default({ client: { session } });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.deepEqual(sent, [{ type: 'usage', sessionId: 'hydrate-root', usage: {
      input: 12, output: 5, reasoning: 1, cacheRead: 3, cacheWrite: 1, cost: 0.5, calls: 2, costKnown: true,
    } }]);
  },

  async partial() {
    process.env.AGENT_OFFICE_SESSION_ID = 'partial-root';
    const session = {
      children: async function () { assert.equal(this, session); throw new Error('children unavailable'); },
      messages: async function () { assert.equal(this, session); return { error: { message: 'messages unavailable' } }; },
    };
    const mod = await import(`${pluginUrl}?partial=${Date.now()}`);
    const hooks = await mod.default({ client: { session } });
    await hooks.event({ event: { type: 'message.updated', properties: { sessionID: 'partial-root', info: {
      id: 'partial-message', sessionID: 'partial-root', role: 'assistant', cost: 0.1,
      tokens: { input: 2, output: 1, reasoning: 0, cache: { read: 0, write: 0 } },
    } } } });
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(sent.filter(event => event.type === 'usage').at(-1)?.usage.incomplete, true);
  },
};

await scenarios[scenario]();
console.log('ok');
''';
