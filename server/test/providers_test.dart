// The provider adapters' command lines (upstream's codex.test.ts, opencode.test.ts and the adapter
// cases of grok/muse/pi/cursor tests), driven through a stand-in WorkerHandle.
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/codex.dart';
import 'package:agent_office_server/src/providers/providers.dart';
import 'package:agent_office_server/src/usage.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_handle.dart';

void main() {
  test("a worker's own model and effort go on Codex's command line, in place of an office-wide model", () {
    expect(codexModelArgs([]), isEmpty);
    expect(codexModelArgs(['--yolo'], 'gpt-5.5', AgentEffort.high), [
      '--yolo',
      '--model',
      'gpt-5.5',
      '-c',
      'model_reasoning_effort="high"',
    ]);
    // Codex refuses --model twice: the office's --agent-args one gives way, however it was written.
    expect(codexModelArgs(['-m', 'gpt-6-astra', '--yolo'], 'gpt-5.5'), ['--yolo', '--model', 'gpt-5.5']);
    expect(codexModelArgs(['--model', 'gpt-6-astra'], 'gpt-5.5'), ['--model', 'gpt-5.5']);
    expect(codexModelArgs(['--model=gpt-6-astra', '-mgpt-6-astra', '--yolo'], 'gpt-5.5'), [
      '--yolo',
      '--model',
      'gpt-5.5',
    ]);
    // With only an effort picked, the office-wide model stays.
    expect(codexModelArgs(['-m', 'gpt-6-astra'], null, AgentEffort.xhigh), [
      '-m',
      'gpt-6-astra',
      '-c',
      'model_reasoning_effort="xhigh"',
    ]);
  });

  test('a Codex worker starts, and resumes, on the model and effort picked for it', () {
    const codex = CodexAdapter();
    List<String> launch(String? model, AgentEffort? effort, {String? prompt, String? resume}) => codex
        .launch(
          LaunchInput(
            h: handleFor(AgentProvider.codex, model: model, effort: effort),
            args: ['--yolo'],
            prompt: prompt,
            resumeSessionId: resume,
            cwd: '/project',
            setup: const CodexSetup(office: ['/opt/agent-office']),
          ),
        )
        .args;
    final fresh = launch('gpt-5.5', AgentEffort.high, prompt: 'fix it');
    expect(fresh.sublist(0, 5), ['--yolo', '--model', 'gpt-5.5', '-c', 'model_reasoning_effort="high"']);
    expect(fresh.sublist(fresh.length - 2), ['--', 'fix it']);
    // Its options come before the `resume` subcommand, which then takes the session.
    final resumed = launch('gpt-5.5', AgentEffort.high, resume: 'thread-1');
    expect(resumed.sublist(0, 5), ['--yolo', '--model', 'gpt-5.5', '-c', 'model_reasoning_effort="high"']);
    expect(resumed.sublist(resumed.length - 2), ['resume', 'thread-1']);
    // Left on its defaults, nothing is added.
    final plain = launch(null, null);
    expect(plain, isNot(contains('--model')));
    expect(plain.any((a) => a.startsWith('model_reasoning_effort')), isFalse);
  });

  test('a Codex board agent stops needing input when the permission tool finishes without a matching prompt id', () {
    final h = handleFor(AgentProvider.codex);
    final handle = const CodexAdapter().hook!.handle;
    bool hook(String event, [Map<String, Object> extra = const {}]) =>
        handle(h, event, {'session_id': 'queue-codex', ...extra});
    expect(hook('SessionStart', {'source': 'startup'}), isTrue);
    expect(h.info.status, WorkerStatus.idle);
    expect(hook('UserPromptSubmit', {'prompt': 'Queue the maintenance issues'}), isTrue);
    expect(h.info.status, WorkerStatus.working);
    expect(hook('PreToolUse', {'tool_name': 'exec_command', 'tool_use_id': 'call-shell'}), isTrue);
    expect(hook('PermissionRequest', {'tool_name': 'shell'}), isTrue);
    expect(h.info.status, WorkerStatus.needsInput);
    expect(hook('PostToolUse', {'tool_name': 'exec_command', 'tool_use_id': 'call-shell'}), isTrue);
    expect(h.info.status, WorkerStatus.working);
    expect(hook('Stop'), isTrue);
    expect(h.info.status, WorkerStatus.done);
  });

  test('an OpenCode worker is told its effort and model for a fresh session, and neither for a resumed one', () {
    const opencode = OpenCodeAdapter();
    ({List<String> args, String? effort, String? model, Map config}) launch(
      String? model,
      AgentEffort? effort, [
      String? resume,
    ]) {
      final plan = opencode.launch(
        LaunchInput(
          h: handleFor(AgentProvider.opencode, model: model, effort: effort),
          args: [],
          resumeSessionId: resume,
          cwd: '/project',
          setup: const OpenCodeSetup(plugin: '/data/agent-office-opencode.mjs'),
        ),
      );
      // What it would have inherited from an office it runs inside is never passed on.
      final env = {'AGENT_OFFICE_EFFORT': 'max', 'AGENT_OFFICE_MODEL': 'someone/elses'};
      plan.finishEnv!(env);
      return (
        args: plan.args,
        effort: env['AGENT_OFFICE_EFFORT'],
        model: env['AGENT_OFFICE_MODEL'],
        config: jsonDecode(env['OPENCODE_CONFIG_CONTENT']!) as Map,
      );
    }

    const model = 'anthropic/claude-opus-5-5';
    final fresh = launch(model, AgentEffort.high);
    expect(fresh.args, ['--model', model]);
    expect([fresh.effort, fresh.model], ['high', model]);
    // The person's own agents are left alone: the effort goes through the plugin.
    expect(fresh.config['agent'], isNull);
    // An effort on OpenCode's own default model.
    expect([launch(null, AgentEffort.low).effort, launch(null, AgentEffort.low).model], ['low', '']);
    expect([launch(model, null).effort, launch(model, null).model], ['', model]);
    final resumed = launch(model, AgentEffort.high, 'ses_1');
    expect(resumed.args, ['--session', 'ses_1']);
    expect([resumed.effort, resumed.model], ['', '']);
  });

  group('usage', () {
    String assistant(String id, String model, [Map<String, Object> more = const {}]) => jsonEncode({
      'type': 'assistant',
      'timestamp': DateTime.utc(2026, 10, 1, 12, 0, int.parse(id)).toIso8601String(),
      ...more,
      'message': {
        'id': 'msg_$id',
        'model': model,
        'usage': {'input_tokens': 10, 'output_tokens': 5},
      },
    });

    test("a Claude session's usage names the model its own latest message ran on", () {
      final dir = Directory.systemTemp.createTempSync('ao-usage-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final transcript = p.join(dir.path, 'session.jsonl');
      final tracker = newTracker()..transcript = transcript;
      expect(trackerUsage(tracker).model, isNull);

      File(transcript).writeAsStringSync('${assistant('1', 'claude-opus-5-5')}\n');
      expect(scanTracker(tracker), isTrue);
      expect(trackerUsage(tracker).model, 'claude-opus-5-5');
      expect(trackerUsage(tracker).calls, 1);

      // A subagent on another model, and Claude Code's own placeholder messages, don't change what the session runs on.
      final subagents = Directory(p.join(dir.path, 'session', 'subagents'))..createSync(recursive: true);
      File(
        p.join(subagents.path, 'agent-1.jsonl'),
      ).writeAsStringSync('${assistant('2', 'claude-haiku-4-5-20251001')}\n');
      final lines = [
        assistant('1', 'claude-opus-5-5'),
        assistant('3', '<synthetic>'),
        assistant('4', 'claude-haiku-4-5-20251001', {'isSidechain': true}),
      ];
      File(transcript).writeAsStringSync('${lines.join('\n')}\n');
      expect(scanTracker(tracker), isTrue);
      expect(trackerUsage(tracker).model, 'claude-opus-5-5');
      expect(trackerUsage(tracker).calls, 4);

      // Switched with /model: the card follows.
      File(transcript).writeAsStringSync('${[...lines, assistant('5', 'claude-sonnet-5-5')].join('\n')}\n');
      scanTracker(tracker);
      expect(trackerUsage(tracker).model, 'claude-sonnet-5-5');

      // And it's kept across a restart, with the rest of the tracker.
      final restored = restoreTracker(jsonDecode(jsonEncode(tracker.toJson())));
      expect(trackerUsage(restored).model, 'claude-sonnet-5-5');
      expect(restoreTracker({...tracker.toJson(), 'model': 'not a model\u0007'}).model, isNull);
    });
  });
}
