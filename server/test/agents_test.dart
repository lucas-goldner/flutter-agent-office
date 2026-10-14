import 'package:agent_office_server/src/agents.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('detects the configured provider from Unix and Windows command paths', () {
    expect(configuredProvider('claude'), AgentProvider.claude);
    expect(configuredProvider('/opt/tools/claude'), AgentProvider.claude);
    expect(configuredProvider(r'C:\Users\me\bin\opencode.exe'), AgentProvider.opencode);
    expect(configuredProvider('/opt/tools/codex'), AgentProvider.codex);
    expect(configuredProvider('CODEX.EXE'), AgentProvider.codex);
    expect(configuredProvider('/home/me/.local/bin/grok'), AgentProvider.grok);
    expect(configuredProvider('GROK.EXE'), AgentProvider.grok);
    expect(configuredProvider('/home/me/.local/bin/muse'), AgentProvider.muse);
    expect(configuredProvider('MUSE.EXE'), AgentProvider.muse);
    // DeepSeek Harness: its own provider now that the office can drive it over ACP.
    expect(configuredProvider('dsh'), AgentProvider.dsh);
    expect(configuredProvider('/opt/tools/dsh'), AgentProvider.dsh);
    expect(configuredProvider('DSH.EXE'), AgentProvider.dsh);
    expect(configuredProvider('pi'), AgentProvider.pi);
    expect(configuredProvider(r'C:\Users\me\AppData\Roaming\npm\pi.cmd'), AgentProvider.pi);
    expect(configuredProvider('/usr/local/bin/pi'), AgentProvider.pi);
    expect(configuredProvider('cursor-agent'), AgentProvider.cursor);
    expect(configuredProvider('/home/me/.local/bin/cursor-agent'), AgentProvider.cursor);
    expect(configuredProvider('cursor-agent.cmd'), AgentProvider.cursor);
    // `cursor` is the editor's launcher, not the agent.
    expect(configuredProvider('cursor'), AgentProvider.custom);
    expect(configuredProvider('my-agent'), AgentProvider.custom);
  });

  test('Pi can be selected with model patterns and thinking levels', () {
    expect(agentProviders(AgentProvider.claude), contains(AgentProvider.pi));
    expect(agentProviders(AgentProvider.custom), contains(AgentProvider.pi));
    expect(agentProviders(AgentProvider.claude), isNot(contains(AgentProvider.custom)));
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.pi, 'anthropic/claude-sonnet-4'), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.pi, 'sonnet'), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.pi, '--print'), contains('Invalid Pi model'));
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.pi, 'bad\u0000model'), contains('Invalid Pi model'));
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.pi, 'high'), isNull);
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.pi, 'invalid'), contains('Invalid effort'));
  });

  test('Cursor can be selected with a model, runs as cursor-agent, and takes no effort', () {
    expect(agentProviders(AgentProvider.claude), contains(AgentProvider.cursor));
    expect(providerCommand(AgentProvider.cursor, 'claude'), 'cursor-agent');
    expect(providerCommand(AgentProvider.cursor, '/opt/bin/cursor-agent'), '/opt/bin/cursor-agent');
    expect(providerCommand(AgentProvider.claude, '/opt/bin/cursor-agent'), 'claude');
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.cursor, null), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.cursor, 'gpt-5'), isNull);
    expect(
      validateWorkerModel(WorkerKind.agent, AgentProvider.cursor, 'claude-opus-4-8[context=1m,effort=high]'),
      isNull,
    );
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.cursor, '--yolo'), contains('Invalid Cursor model'));
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.cursor, 'gpt 5'), contains('Invalid Cursor model'));
    expect(
      validateWorkerEffort(WorkerKind.agent, AgentProvider.cursor, 'high'),
      contains('Reasoning effort can only be selected'),
    );
  });

  test('model validation follows the provider', () {
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.dsh, null), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.dsh, 'deepseek-v4-pro'), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.dsh, 'bad\u0001'), contains('DeepSeek Harness'));
    expect(validateWorkerModel(WorkerKind.shell, AgentProvider.dsh, 'deepseek-v4-pro'), contains('Shell workers'));
    // Claude and OpenCode keep their own rules.
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.claude, 'opus'), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.claude, 'gpt-5'), contains('Claude'));
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.opencode, 'vendor/model'), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.opencode, 'gpt-5'), contains('OpenCode'));
    // Codex takes its own model ids, and a local provider's.
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.codex, 'gpt-5.5'), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.codex, 'gpt-oss:20b'), isNull);
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.codex, '--yolo'), contains('Invalid Codex model'));
    expect(validateWorkerModel(WorkerKind.agent, AgentProvider.codex, 'gpt 5.5'), contains('Invalid Codex model'));
    // Custom still takes none.
    expect(
      validateWorkerModel(WorkerKind.agent, AgentProvider.custom, 'anything'),
      contains('Claude Code, OpenCode, Codex, Grok, Muse, DeepSeek Harness, Pi or Cursor'),
    );
  });

  test('reasoning effort joins Claude for every harness but Cursor', () {
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.dsh, null), isNull);
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.dsh, 'high'), isNull);
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.dsh, 'enormous'), contains('Invalid effort'));
    expect(validateWorkerEffort(WorkerKind.shell, AgentProvider.dsh, 'high'), contains('Shell workers'));
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.claude, AgentEffort.xhigh), isNull);
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.codex, 'high'), isNull);
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.opencode, 'high'), isNull);
    expect(validateWorkerEffort(WorkerKind.agent, AgentProvider.opencode, 'enormous'), contains('Invalid effort'));
    expect(
      validateWorkerEffort(WorkerKind.agent, AgentProvider.custom, 'high'),
      contains('Claude Code, OpenCode, Codex, Grok, Muse, DeepSeek Harness or Pi'),
    );
  });
}
