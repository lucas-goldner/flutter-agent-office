import 'dart:async';
import 'dart:io';

import 'package:agent_office_server/src/agents.dart';
import 'package:agent_office_server/src/models.dart';
import 'package:test/test.dart';

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
    ({String file, List<String> args, ModelCommandOptions options})? call;
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      call = (file: file, args: args, options: options);
      return (stdout: 'openai/gpt-5\nopenrouter/deepseek/deepseek-r1\nopenai/gpt-5\n', stderr: 'private detail');
    }

    expect(await fetchOpenCodeModels('/custom/opencode', '/project', runner), [
      'openai/gpt-5',
      'openrouter/deepseek/deepseek-r1',
    ]);
    expect(call!.file, '/custom/opencode');
    expect(call!.args, ['models']);
    expect(call!.options.cwd, '/project');
    expect(call!.options.timeout, 10000);
    expect(call!.options.maxBuffer, 1024 * 1024);
  });

  test('OpenCode catalogue coalesces requests and caches successful results briefly', () async {
    var calls = 0;
    var now = 1000;
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return (stdout: 'anthropic/claude-sonnet-4\n', stderr: '');
    }

    final catalogue = createOpenCodeModelCatalogue('/opencode', '/project', runner, () => now);
    final [a, b] = await Future.wait([catalogue.get(), catalogue.get()]);
    expect(a, ['anthropic/claude-sonnet-4']);
    expect(b, a);
    expect(calls, 1);
    now += 59999;
    await catalogue.get();
    expect(calls, 1);
    now += 2;
    await catalogue.get();
    expect(calls, 2);
  });

  test('OpenCode catalogue errors do not expose command output', () async {
    Future<ModelCommandResult> runner(String file, List<String> args, ModelCommandOptions options) async {
      throw Exception('secret-token from stderr');
    }

    Matcher unavailable() => isA<StateError>().having(
      (e) => e.message,
      'message',
      allOf(matches(RegExp('unavailable', caseSensitive: false)), isNot(contains('secret-token'))),
    );
    await expectLater(fetchOpenCodeModels('opencode', '/project', runner), throwsA(unavailable()));
    await expectLater(createOpenCodeModelCatalogue('opencode', '/project', runner).get(), throwsA(unavailable()));
  });

  test('the default runner runs the executable without a shell and strips ANSI styling', () async {
    // Not in the TS suite: the Node runner was execFile; this checks the Dart stand-in end to end.
    final dir = Directory.systemTemp.createTempSync('agent-office-models-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File('${dir.path}/opencode')
      ..writeAsStringSync(
        "#!/bin/sh\n[ \"\$1\" = models ] || exit 3\nprintf 'openai/gpt-5\\n\\033[1m- anthropic/claude-sonnet-4\\033[0m\\n'\n",
      );
    Process.runSync('chmod', ['755', script.path]);
    expect(await fetchOpenCodeModels(script.path, dir.path), ['openai/gpt-5', 'anthropic/claude-sonnet-4']);
    File('${dir.path}/fail').writeAsStringSync('#!/bin/sh\nexit 1\n');
    Process.runSync('chmod', ['755', '${dir.path}/fail']);
    await expectLater(fetchOpenCodeModels('${dir.path}/fail', dir.path), throwsA(isA<StateError>()));
  });
}
