// The shared parts of tests/agents.test.ts, models.test.ts, cursor.test.ts and pi.test.ts: what the
// office knows about each provider, and which model ids get through to a command line.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('OpenCode model ids require provider/model and reject whitespace or control characters', () {
    expect(isValidOpenCodeModel('openai/gpt-5'), isTrue);
    expect(isValidOpenCodeModel('openrouter/deepseek/deepseek-r1'), isTrue);
    expect(isValidOpenCodeModel('gpt-5'), isFalse);
    expect(isValidOpenCodeModel('openai/gpt 5'), isFalse);
    expect(isValidOpenCodeModel('openai/gpt\n5'), isFalse);
    expect(isValidOpenCodeModel('openai/${'x' * 256}'), isFalse);
  });

  test('Grok and Muse model ids are argv-safe tokens without a provider prefix', () {
    expect(isValidGrokModel('grok-4.6'), isTrue);
    expect(isValidGrokModel('grok-4.7-build-fast'), isTrue);
    expect(isValidGrokModel('openai/gpt-5'), isFalse);
    expect(isValidGrokModel('grok 4.6'), isFalse);
    expect(isValidGrokModel('x' * 65), isFalse);
    expect(isValidMuseModel('muse-spark-1.3-contributor'), isTrue);
    expect(isValidMuseModel('openai/gpt-5'), isFalse);
    expect(isValidMuseModel('muse spark'), isFalse);
    expect(isValidMuseModel('x' * 129), isFalse);
  });

  test('DeepSeek Harness ids are opaque: only their length and control characters are checked', () {
    expect(isValidDshModel('deepseek-v4-pro'), isTrue);
    expect(isValidDshModel('Some Vendor/Model-2.1'), isTrue);
    expect(isValidDshModel('x' * 256), isTrue);
    expect(isValidDshModel('x' * 257), isFalse);
    expect(isValidDshModel(''), isFalse);
    expect(isValidDshModel('pro\u0000'), isFalse);
    expect(isValidDshModel('pro​'), isFalse, reason: 'format characters are rejected too');
    expect(isValidDshModel(42), isFalse);
    expect(isValidDshModel(null), isFalse);
  });

  test('Codex model ids are argv-safe', () {
    expect(isValidCodexModel('gpt-5.5'), isTrue);
    expect(isValidCodexModel('openai/gpt-oss-20b'), isTrue);
    expect(isValidCodexModel('-m'), isFalse);
    expect(isValidCodexModel('gpt-5.5 --yolo'), isFalse);
    expect(isValidCodexModel('gpt"5'), isFalse);
    expect(isValidCodexModel('x' * 129), isFalse);
    expect(isValidCodexModel(''), isFalse);
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
      '',
      '--force',
      '-m',
      'gpt 5',
      'gpt-5[effort]',
      'gpt-5[effort=high',
      'gpt-5]',
      'a/b',
      'gpt-5;rm',
      'gpt\u00005',
      'x' * 129,
      42,
      null,
    ]) {
      expect(isValidCursorModel(bad), isFalse, reason: '$bad');
    }
  });

  test('Pi model ids are plain values, nothing cmd.exe would read', () {
    expect(isValidPiModel('sonnet:high'), isTrue);
    expect(isValidPiModel('openai/gpt-4.1'), isTrue);
    expect(isValidPiModel('--print'), isFalse);
    expect(isValidPiModel('bad​model'), isFalse);
    for (final model in ['a&b', 'a|b', 'a^b', '%PATH%', 'a<b', 'a>b', 'a"b', '-m']) {
      expect(isValidPiModel(model), isFalse, reason: model);
    }
  });

  test(
    'every provider the office knows the CLI of takes a model and (but for Cursor) an effort, with the fields to pick them',
    () {
      for (final provider in AgentProvider.values) {
        final meta = providerMetaTable[provider]!;
        if (provider == AgentProvider.custom) {
          expect(meta.validModel, isNull);
          expect(meta.takesEffort, isFalse);
          expect(meta.unpicked, isNotNull);
          continue;
        }
        expect(meta.validModel != null && meta.invalidModel != null, isTrue, reason: '$provider takes a model');
        if (provider == AgentProvider.cursor) {
          expect(meta.takesEffort, isFalse);
        } else {
          expect(meta.takesEffort, isTrue, reason: '$provider takes an effort');
        }
        final models = meta.models!;
        expect(models.unset.isNotEmpty && models.hint.isNotEmpty, isTrue);
        if (models.pick == ModelPick.list) expect((models.fixed?.isNotEmpty ?? false) || models.catalog, isTrue);
        if (models.pick == ModelPick.typed || models.catalog)
          expect(models.invalid != null && models.max != null, isTrue);
        for (final m in models.fixed ?? const <ModelOption>[]) {
          expect(meta.validModel!(m.id), isTrue, reason: '$provider takes its own ${m.id}');
        }
      }
      expect(AgentProvider.values.map((p) => p.wire), [
        'claude',
        'opencode',
        'codex',
        'grok',
        'muse',
        'dsh',
        'pi',
        'cursor',
        'custom',
      ]);
    },
  );

  test('Claude models go by the name of the model, not only its family', () {
    for (final alias in claudeModels) {
      expect(claudeModelNames[alias], matches(RegExp(r'^[A-Z][a-z]+ \d+(\.\d+)?$')));
    }
    expect(
      [for (final m in providerMetaTable[AgentProvider.claude]!.models!.fixed!) m.name],
      [for (final m in claudeModels) claudeModelNames[m]],
    );
    expect(claudeModelName('claude-opus-5-5'), 'Opus 5.5');
    expect(claudeModelName('claude-fable-5-1'), 'Fable 5.1');
    expect(claudeModelName('claude-haiku-4-5-20251001'), 'Haiku 4.5');
    expect(claudeModelName('claude-sonnet-5'), 'Sonnet 5');
    expect(claudeModelName('claude-sonnet-4-20250514'), 'Sonnet 4');
    expect(claudeModelName('claude-opus-4-1-20250805'), 'Opus 4.1');
    expect(claudeModelName('claude-3-5-sonnet-20241022'), 'Sonnet 3.5');
    expect(claudeModelName('claude-opus-5-5[1m]'), 'Opus 5.5');
    expect(claudeModelName('us.anthropic.claude-opus-5-5-v1:0'), 'Opus 5.5');
    expect(claudeModelName('gpt-5.5'), isNull);
    expect(claudeModelName('<synthetic>'), isNull);
  });

  test('saved models and efforts only come back for a provider that takes them', () {
    expect(savedModel('claude', 'opus'), 'opus');
    expect(savedModel(AgentProvider.claude, 'openai/gpt-5'), isNull);
    expect(savedModel('custom', 'opus'), isNull);
    expect(savedModel('nope', 'opus'), isNull);
    expect(savedEffort('cursor', 'high'), isNull);
    expect(savedEffort('pi', 'high'), AgentEffort.high);
    expect(savedEffort('pi', 'enormous'), isNull);
    expect(takesModel('custom'), isFalse);
    expect(takesEffort(AgentProvider.grok), isTrue);
    expect(providerNames((m) => m.takesEffort), 'Claude Code, OpenCode, Codex, Grok, Muse, DeepSeek Harness or Pi');
  });
}
