import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/models.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

typedef _Call = ({String file, List<String> args, ModelCommandOptions options});

List<Map<String, dynamic>> _json(List<ModelOption> models) => [for (final m in models) m.toJson()];
List<String> _ids(List<ModelOption> models) => [for (final m in models) m.id];

Matcher _unavailable([String? secret]) => isA<StateError>().having(
  (e) => e.message,
  'message',
  allOf(matches(RegExp('unavailable', caseSensitive: false)), isNot(contains(secret ?? '\u0000'))),
);

void main() {
  test('OpenCode model ids require provider/model and reject whitespace or control characters', () {
    expect(isValidOpenCodeModel('openai/gpt-5'), true);
    expect(isValidOpenCodeModel('openrouter/deepseek/deepseek-r1'), true);
    expect(isValidOpenCodeModel('gpt-5'), false);
    expect(isValidOpenCodeModel('openai/gpt 5'), false);
    expect(isValidOpenCodeModel('openai/gpt\n5'), false);
    expect(isValidOpenCodeModel('openai/${'x' * 256}'), false);
  });

  test('OpenCode catalogue invokes only the configured executable with bounded execFile options', () async {
    final calls = <_Call>[];
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      calls.add((file: file, args: args, options: options));
      // An OpenCode without --verbose: it's turned down, and the plain list is asked for.
      if (args.contains('--verbose')) throw Exception('Unknown argument: verbose');
      return (stdout: 'openai/gpt-5\nopenrouter/deepseek/deepseek-r1\nopenai/gpt-5\n', stderr: 'private detail');
    }

    expect(_json(await fetchOpenCodeModels('/custom/opencode', '/project', runner)), [
      {'id': 'openai/gpt-5'},
      {'id': 'openrouter/deepseek/deepseek-r1'},
    ]);
    expect(
      calls,
      [
            (
              file: '/custom/opencode',
              args: ['models', '--verbose'],
              options: const ModelCommandOptions(cwd: '/project', timeout: 30000, maxBuffer: 16 * 1024 * 1024),
            ),
            (
              file: '/custom/opencode',
              args: ['models'],
              options: const ModelCommandOptions(cwd: '/project', timeout: 30000, maxBuffer: 1024 * 1024),
            ),
          ]
          .map(
            (c) => isA<_Call>()
                .having((x) => x.file, 'file', c.file)
                .having((x) => x.args, 'args', c.args)
                .having((x) => x.options, 'options', c.options),
          )
          .toList(),
    );
  });

  test("OpenCode catalogue takes each model's name and its variants as the efforts it can run at", () async {
    String pretty(Object o) => const JsonEncoderPretty().convert(o);
    final stdout = [
      'opencode/big-pickle',
      pretty({'id': 'big-pickle', 'providerID': 'opencode', 'name': 'Big Pickle', 'options': {}, 'variants': {}}),
      'amazon-bedrock/anthropic.claude-opus-5-5',
      pretty({
        'id': 'anthropic.claude-opus-5-5',
        'name': 'Claude Opus 5.5',
        'limit': {'context': 200000},
        'variants': {
          'low': {'a': 1},
          'medium': {},
          'high': {},
          'max': {},
        },
      }),
      'openai/gpt-5',
      pretty({
        'id': 'gpt-5',
        'name': 'GPT-5',
        'variants': {'minimal': {}, 'low': {}, 'medium': {}, 'high': {}},
      }),
      'local/plain',
      'local/odd',
      '{ not json',
      '}',
      'local/unnamed',
      pretty({'id': 'unnamed', 'name': 'local/unnamed'}),
      '',
    ].join('\n');
    final models = await fetchOpenCodeModels('opencode', '/project', (_, _, _) async => (stdout: stdout, stderr: ''));
    expect(_json(models), [
      {'id': 'opencode/big-pickle', 'name': 'Big Pickle', 'efforts': <String>[]},
      {
        'id': 'amazon-bedrock/anthropic.claude-opus-5-5',
        'name': 'Claude Opus 5.5',
        'efforts': ['low', 'medium', 'high', 'max'],
      },
      // Variants the office has no effort for ("minimal") are left out.
      {
        'id': 'openai/gpt-5',
        'name': 'GPT-5',
        'efforts': ['low', 'medium', 'high'],
      },
      // No details, or ones that don't parse: still a model, with any effort.
      {'id': 'local/plain'},
      {'id': 'local/odd'},
      // A name that only repeats the id says nothing.
      {'id': 'local/unnamed'},
    ]);
  });

  test('Codex catalogue lists the models its own picker shows, by name, with the efforts each supports', () async {
    _Call? call;
    List<Map<String, String>> levels(List<String> efforts) => [
      for (final e in efforts) {'effort': e, 'description': 'x'},
    ];
    final stdout = const JsonEncoderPretty().convert({
      'models': [
        {
          'slug': 'gpt-6-astra',
          'display_name': 'GPT-6-Astra',
          'visibility': 'list',
          'supported_reasoning_levels': levels(['low', 'medium', 'high', 'xhigh', 'max', 'ultra']),
          'base_instructions': 'x' * 4000,
        },
        {
          'slug': 'gpt-reserve',
          'display_name': 'GPT-Reserve',
          'visibility': 'hide',
          'supported_reasoning_levels': levels(['low']),
        },
        {
          'slug': 'gpt-5.5',
          'display_name': 'GPT-5.5',
          'visibility': 'list',
          'supported_reasoning_levels': levels(['low', 'medium', 'high', 'xhigh']),
        },
        {'slug': 'bad slug', 'display_name': 'Nope', 'visibility': 'list'},
        {'slug': 'gpt-oss:20b', 'display_name': 'gpt-oss:20b'},
        {'slug': 'gpt-6-astra', 'display_name': 'Again', 'visibility': 'list'},
        'junk',
      ],
    });
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      call = (file: file, args: args, options: options);
      return (stdout: stdout, stderr: '');
    }

    expect(_json(await fetchCodexModels('/custom/codex', '/project', runner)), [
      {
        'id': 'gpt-6-astra',
        'name': 'GPT-6-Astra',
        'efforts': ['low', 'medium', 'high', 'xhigh', 'max'],
      },
      {
        'id': 'gpt-5.5',
        'name': 'GPT-5.5',
        'efforts': ['low', 'medium', 'high', 'xhigh'],
      },
      {'id': 'gpt-oss:20b'},
    ]);
    expect(call!.file, '/custom/codex');
    expect(call!.args, ['debug', 'models']);
    expect(call!.options, const ModelCommandOptions(cwd: '/project', timeout: 30000, maxBuffer: 16 * 1024 * 1024));
  });

  test('Codex catalogue errors do not expose command output', () async {
    await expectLater(
      fetchCodexModels(
        'codex',
        '/project',
        (_, _, _) async => (stdout: 'error: unrecognized subcommand', stderr: 'secret-token'),
      ),
      throwsA(_unavailable('secret-token')),
    );
    await expectLater(
      fetchCodexModels('codex', '/project', (_, _, _) async => (stdout: '{"models":"none"}', stderr: '')),
      throwsA(_unavailable()),
    );
  });

  test('every provider that says its CLI lists its models has a lister, and only those', () {
    final listed = {
      for (final p in AgentProvider.values)
        if (providerMetaTable[p]!.models?.catalog ?? false) p,
    };
    expect(modelListers.keys.toSet(), listed);
  });

  test('OpenCode catalogue coalesces requests and caches successful results briefly', () async {
    var calls = 0;
    var now = 1000;
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return (stdout: 'anthropic/claude-sonnet-4\n', stderr: '');
    }

    final catalogue = createModelCatalogue(() => fetchOpenCodeModels('/opencode', '/project', runner), () => now);
    final [a, b] = await Future.wait([catalogue.get(), catalogue.get()]);
    expect(_json(a), [
      {'id': 'anthropic/claude-sonnet-4'},
    ]);
    expect(_json(b), _json(a));
    expect(calls, 1);
    now += 59999;
    await catalogue.get();
    expect(calls, 1);
    now += 2;
    await catalogue.get();
    expect(calls, 2);
  });

  test('Grok model ids are argv-safe tokens without a provider prefix', () {
    expect(isValidGrokModel('grok-4.6'), true);
    expect(isValidGrokModel('grok-4.7-build-fast'), true);
    expect(isValidGrokModel('openai/gpt-5'), false);
    expect(isValidGrokModel('grok 4.6'), false);
    expect(isValidGrokModel('x' * 65), false);
  });

  test('Muse model ids are argv-safe tokens without a provider prefix', () {
    expect(isValidMuseModel('muse-spark-1.3-contributor'), true);
    expect(isValidMuseModel('openai/gpt-5'), false);
    expect(isValidMuseModel('muse spark'), false);
    expect(isValidMuseModel('x' * 129), false);
  });

  test('Grok catalogue parses `grok models` lines and ignores login chrome', () async {
    _Call? call;
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      call = (file: file, args: args, options: options);
      return (
        stdout:
            'You are logged in with grok.com.\n\nDefault model: grok-4.6\n\nAvailable models:\n  - grok-4.7\n  * grok-4.6 (default)\n  - grok-4.5\n',
        stderr: 'private detail',
      );
    }

    expect(_ids(await fetchGrokModels('/custom/grok', '/project', runner)), ['grok-4.7', 'grok-4.6', 'grok-4.5']);
    expect(call!.file, '/custom/grok');
    expect(call!.args, ['models']);
    expect(call!.options, const ModelCommandOptions(cwd: '/project', timeout: 30000, maxBuffer: 1024 * 1024));
  });

  test('Grok catalogue coalesces requests and caches successful results briefly', () async {
    var calls = 0;
    var now = 1000;
    final catalogue = createModelCatalogue(
      () => fetchGrokModels('/grok', '/project', (_, _, _) async {
        calls++;
        return (stdout: '  - grok-4.6\n', stderr: '');
      }),
      () => now,
    );
    final [a, b] = await Future.wait([catalogue.get(), catalogue.get()]);
    expect(_ids(a), ['grok-4.6']);
    expect(_ids(b), _ids(a));
    expect(calls, 1);
    now += 59999;
    await catalogue.get();
    expect(calls, 1);
    now += 2;
    await catalogue.get();
    expect(calls, 2);
  });

  test(
    "Cursor catalogue parses `cursor-agent models` lines, with each model's name, and ignores the heading and tip",
    () async {
      _Call? call;
      Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
        call = (file: file, args: args, options: options);
        return (
          stdout: [
            '\x1b[2mAvailable models\x1b[22m',
            '',
            '\x1b[36mauto\x1b[39m \x1b[2m- Auto\x1b[22m',
            '\x1b[32mcomposer-2.5\x1b[39m \x1b[2m- Composer 2.5\x1b[22m\x1b[2m (current, default)\x1b[22m',
            'gpt-5 - GPT-5',
            'sonnet-4-thinking',
            'gpt-5 - GPT-5',
            'bad/model - Not a Cursor id',
            '',
            "Tip: use --model <id> (or /model <id> in interactive mode) to switch. Parameterized models also accept quoted overrides, e.g. --model 'claude-opus-4-8[context=1m,effort=high,fast=false]'.",
          ].join('\n'),
          stderr: 'private detail',
        );
      }

      expect(_json(await fetchCursorModels('/custom/cursor-agent', '/project', runner)), [
        {'id': 'auto', 'name': 'Auto'},
        {'id': 'composer-2.5', 'name': 'Composer 2.5'},
        {'id': 'gpt-5', 'name': 'GPT-5'},
        {'id': 'sonnet-4-thinking'},
      ]);
      expect(call!.file, '/custom/cursor-agent');
      expect(call!.args, ['models']);
      expect(call!.options, const ModelCommandOptions(cwd: '/project', timeout: 30000, maxBuffer: 1024 * 1024));
      expect(
        await fetchCursorModels(
          'cursor-agent',
          '/project',
          (_, _, _) async => (stdout: 'No models available for this account.\n', stderr: ''),
        ),
        isEmpty,
      );
    },
  );

  test('Cursor catalogue caches briefly and hides why it failed (not signed in)', () async {
    var calls = 0;
    final catalogue = createModelCatalogue(
      () => fetchCursorModels('/cursor-agent', '/project', (_, _, _) async {
        calls++;
        return (stdout: 'gpt-5 - GPT-5\n', stderr: '');
      }),
    );
    final [a, b] = await Future.wait([catalogue.get(), catalogue.get()]);
    expect(
      [_json(a), _json(b)],
      [
        [
          {'id': 'gpt-5', 'name': 'GPT-5'},
        ],
        [
          {'id': 'gpt-5', 'name': 'GPT-5'},
        ],
      ],
    );
    await catalogue.get();
    expect(calls, 1);
    await expectLater(
      createModelCatalogue(
        () => fetchCursorModels('cursor-agent', '/project', (_, _, _) async {
          throw Exception("Authentication required. Run 'agent login'");
        }),
      ).get(),
      throwsA(_unavailable('Authentication')),
    );
  });

  test('a catalogue past its minute still answers at once with the last list, and asks again for the next', () async {
    var now = 1000;
    var calls = 0;
    var fail = false;
    final catalogue = createModelCatalogue(() async {
      calls++;
      if (fail) throw StateError('gone');
      return [ModelOption(id: 'model-$calls')];
    }, () => now);
    expect(_ids(await catalogue.get()), ['model-1']);
    now += 60001;
    expect(_ids(await catalogue.get()), ['model-1']);
    expect(calls, 2);
    expect(_ids(await catalogue.get()), ['model-2']);
    // A CLI that can't list them any more leaves the last list standing.
    fail = true;
    now += 60001;
    expect(_ids(await catalogue.get()), ['model-2']);
    await Future<void>.delayed(Duration.zero);
    expect(_ids(await catalogue.get()), ['model-2']);
    // One that never could says so.
    await expectLater(createModelCatalogue(() => Future.error(StateError('gone'))).get(), throwsA(isA<StateError>()));
  });

  test('OpenCode catalogue errors do not expose command output', () async {
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      throw Exception('secret-token from stderr');
    }

    await expectLater(fetchOpenCodeModels('opencode', '/project', runner), throwsA(_unavailable('secret-token')));
    await expectLater(
      createModelCatalogue(() => fetchOpenCodeModels('opencode', '/project', runner)).get(),
      throwsA(_unavailable('secret-token')),
    );
  });

  test('the default runner runs the executable without a shell and strips ANSI styling', () async {
    // Not in the TS suite: the Node runner was execFile; this checks the Dart stand-in end to end.
    final dir = Directory.systemTemp.createTempSync('agent-office-models-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File('${dir.path}/opencode')
      ..writeAsStringSync(
        "#!/bin/sh\n[ \"\$1\" = models ] || exit 3\n[ -z \"\$2\" ] || exit 4\nprintf 'openai/gpt-5\\n\\033[1m- anthropic/claude-sonnet-4\\033[0m\\n'\n",
      );
    Process.runSync('chmod', ['755', script.path]);
    expect(_ids(await fetchOpenCodeModels(script.path, dir.path)), ['openai/gpt-5', 'anthropic/claude-sonnet-4']);
    File('${dir.path}/fail').writeAsStringSync('#!/bin/sh\nexit 1\n');
    Process.runSync('chmod', ['755', '${dir.path}/fail']);
    await expectLater(fetchOpenCodeModels('${dir.path}/fail', dir.path), throwsA(isA<StateError>()));
  });
}

/// JSON.stringify(o, null, 2).
class JsonEncoderPretty {
  const JsonEncoderPretty();
  String convert(Object o) => const JsonEncoder.withIndent('  ').convert(o);
}
