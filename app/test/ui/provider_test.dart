// Picking a worker (#79 #88 #137): the office's default (⚙️ Settings, else the --agent), ✏️ Edit
// for another provider, model and effort, and how a choice reads; the queue sends it.

import 'package:agent_office/ui/provider.dart';
import 'package:agent_office/ui/queue.dart';
import 'package:agent_office/ui/queue_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/providers.dart' show ModelOption;

import 'harness.dart';

ProjectInfo project({String def = 'claude', List<String> providers = const ['claude', 'opencode']}) =>
    ProjectInfo.fromJson({
      'name': 'p',
      'dir': '/p',
      'agentCmd': 'claude',
      'defaultProvider': def,
      'agentProviders': providers,
    });

PromptsAgent picked(String provider, {String? model, String? effort}) =>
    PromptsAgent.fromJson({'provider': provider, 'model': ?model, 'effort': ?effort, 'by': 'Ada', 'at': 1});

void main() {
  test('badges and labels', () {
    expect(modelBadge(AgentProvider.claude, 'opus', AgentEffort.high), 'Opus 5.5 · High');
    expect(modelBadge(AgentProvider.claude, 'fable', null), 'Fable 5.1');
    // What its session says it runs is surer than what an alias stands for.
    expect(modelBadge(AgentProvider.claude, 'opus', null, 'claude-sonnet-5-5'), 'Sonnet 5.5');
    expect(modelBadge(AgentProvider.claude, null, null, 'claude-haiku-4-5-20251001'), 'Haiku 4.5');
    expect(modelBadge(AgentProvider.codex, 'gpt-5.5', AgentEffort.high), 'gpt-5.5 · High');
    expect(modelBadge(AgentProvider.cursor, 'gpt-5', AgentEffort.high), 'gpt-5', reason: 'Cursor takes no effort');
    expect(modelBadge(AgentProvider.claude, null, AgentEffort.xhigh), 'Extra high');
    expect(modelBadge(AgentProvider.opencode, 'anthropic/claude-sonnet-4', null), 'anthropic/claude-sonnet-4');
    expect(modelBadge(AgentProvider.claude, null, null), isNull);
    expect(choiceLabel(const AgentChoice(provider: AgentProvider.claude)), 'Claude Code');
    expect(
      choiceLabel(const AgentChoice(provider: AgentProvider.claude, model: 'opus', effort: AgentEffort.max)),
      'Claude Code · Opus 5.5 · Max',
    );
  });

  test("the office's default: picked in Settings, when the project offers it", () {
    final p = project();
    expect(officeChoice(p, null).provider, AgentProvider.claude);
    final c = officeChoice(p, picked('claude', model: 'sonnet', effort: 'low'));
    expect((c.provider, c.model, c.effort), (AgentProvider.claude, 'sonnet', AgentEffort.low));
    expect(officeChoice(p, picked('codex')).provider, AgentProvider.claude, reason: 'codex is not offered here');
    expect(officeChoice(project(def: 'opencode'), null).provider, AgentProvider.opencode);
  });

  test('the picker starts on the default; ✏️ Edit picks another for this one', () {
    final c = ProviderPickerController(
      project(),
      office: picked('claude', model: 'opus', effort: 'high'),
    );
    expect(c.editing, isFalse);
    expect((c.value(), c.model(), c.effort()), (AgentProvider.claude, 'opus', AgentEffort.high));
    c.toggleEdit();
    expect(c.editing, isTrue);
    expect(c.claudeModel, 'opus', reason: 'the fields open on the default');
    c.claudeModel = 'haiku';
    c.effortPicked = null;
    expect((c.model(), c.effort()), ('haiku', null));
    c.selected = AgentProvider.opencode;
    expect(c.effort(), isNull, reason: 'another provider starts on its own defaults');
    c.modelText.text = 'openrouter/x';
    expect(c.choice().model, 'openrouter/x');
    c.toggleEdit();
    expect((c.value(), c.model()), (AgentProvider.claude, 'opus'));
    // The default changes in Settings while it's open.
    c.office = picked('opencode', model: 'a/b');
    expect((c.value(), c.model()), (AgentProvider.opencode, 'a/b'));
    c.dispose();
  });

  test('as Settings’ fields it is always open, and set() puts it on a choice', () {
    final c = ProviderPickerController(project(), fields: true);
    expect(c.editing, isTrue);
    c.set(const AgentChoice(provider: AgentProvider.claude, model: 'nope', effort: AgentEffort.medium));
    expect((c.claudeModel, c.effortPicked), (null, AgentEffort.medium));
    c.set(const AgentChoice(provider: AgentProvider.codex));
    expect(c.value(), AgentProvider.claude, reason: 'not offered: the fallback');
    c.dispose();
  });

  test('queue lines name the model and effort', () {
    final t = QueueTask.fromJson({
      'id': 't1',
      'title': 'Fix it',
      'prompt': 'Fix it',
      'status': 'queued',
      'addedBy': 'Ada',
      'addedAt': 0,
      'provider': 'claude',
      'model': 'opus',
      'effort': 'high',
    });
    expect(taskMeta(t), contains('initial: Opus 5.5 · High'));
  });

  testWidgets('the queue adds a task on the default, or on what ✏️ Edit picked', (tester) async {
    final office = Office()..welcome();
    office.store.apply(
      ServerMsg.parse({
        't': 'prompts',
        'state': {
          'custom': {},
          'agent': {'provider': 'claude', 'model': 'sonnet', 'by': 'Ada', 'at': 1},
        },
      }),
    );
    await office.pump(tester, const SizedBox());
    openQueue(office.scope());
    await tester.pump();
    await tester.pump();
    expect(find.text('Claude Code · Sonnet 5.5'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Write the docs');
    await tester.tap(find.text('Add to queue'));
    await tester.pump();
    var add = office.net.sent.whereType<QueueAddCmd>().last;
    expect((add.prompt, add.provider, add.model, add.effort), ('Write the docs', AgentProvider.claude, 'sonnet', null));

    await tester.tap(find.byKey(const ValueKey('provider-edit')));
    await tester.pump();
    expect(find.byKey(const ValueKey('provider-effort')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('provider-effort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Think hard');
    await tester.tap(find.text('Add to queue'));
    await tester.pump();
    add = office.net.sent.whereType<QueueAddCmd>().last;
    expect((add.model, add.effort), ('sonnet', AgentEffort.max));
  });

  test('every provider’s fields come from its row in the table', () {
    final p = project(providers: ['claude', 'opencode', 'codex', 'grok', 'muse', 'dsh', 'pi', 'cursor', 'custom']);
    final c = ProviderPickerController(p, fields: true);
    // Codex lists its models with the efforts each takes.
    setCatalogue(
      AgentProvider.codex,
      list: [
        const ModelOption(id: 'gpt-5.5', name: 'GPT-5.5', efforts: [AgentEffort.low, AgentEffort.high]),
        const ModelOption(id: 'gpt-5-mini', efforts: []),
      ],
    );
    c.selected = AgentProvider.codex;
    expect(c.typed, isFalse);
    c.chosen = 'gpt-5.5';
    c.effortPicked = AgentEffort.high;
    expect(c.choice().model, 'gpt-5.5');
    expect(c.choice().effort, AgentEffort.high);
    c.chosen = 'gpt-5-mini';
    expect(c.effortPicked, isNull, reason: 'that model takes no effort');
    // A list that couldn't be had: typed in.
    setCatalogue(AgentProvider.grok, failed: true);
    c.selected = AgentProvider.grok;
    expect(c.typed, isTrue);
    c.modelText.text = 'grok 4';
    expect(c.valid(), isFalse);
    expect(c.modelError, 'Use a Grok model id without whitespace (up to 64 characters).');
    // Pi's effort is its thinking; Cursor has none to pick; a custom --agent has neither.
    c.selected = AgentProvider.pi;
    expect(c.meta.effortLabel, 'Thinking');
    c.selected = AgentProvider.cursor;
    c.effortPicked = AgentEffort.high;
    expect(c.effort(), isNull);
    c.selected = AgentProvider.custom;
    expect(c.meta.models, isNull);
    expect(c.choice().model, isNull);
    c.dispose();
  });

  test('the office lists a provider’s models, valid ones once each; an older office sent plain ids', () {
    final models = parseModels(AgentProvider.codex, {
      'models': [
        {
          'id': 'gpt-5.5',
          'name': 'GPT-5.5',
          'efforts': ['low', 'nope'],
        },
        {'id': 'gpt-5.5'},
        {'id': 'has space'},
        'gpt-4.1',
      ],
    });
    expect([for (final m in models) m.id], ['gpt-5.5', 'gpt-4.1']);
    expect(models.first.efforts, [AgentEffort.low]);
    expect(parseModels(AgentProvider.opencode, {'models': 'x'}), isEmpty);
  });

  test('usage: tracked, waiting for a first report, or untracked, by provider', () {
    final p = project();
    expect(providerUsageState(AgentProvider.claude, p), ProviderUsageState.waiting);
    expect(providerUsageState(AgentProvider.dsh, p), ProviderUsageState.waiting);
    expect(providerWaitingLabel(AgentProvider.dsh, p), 'waiting for first report');
    expect(providerUsageState(AgentProvider.grok, p), ProviderUsageState.untracked);
    expect(
      providerUsageState(
        AgentProvider.pi,
        p,
        const Usage(input: 1, output: 0, cacheWrite: 0, cacheRead: 0, cost: 0, calls: 1),
      ),
      ProviderUsageState.tracked,
    );
  });
}
