// Worker templates in the Hire dialog: a tap fills it in and hires under the template's name; ＋ keeps
// what's in the dialog as a new one; ✏️ changes or removes one. The whole list goes to the office.

import 'package:agent_office/ui/prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void main() {
  testWidgets('pick a template, hire under its name; save a new one; edit and remove', (tester) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox());
    final hired = <(String, PromptChoice)>[];
    final kept = <List<WorkerTemplate>>[];
    void open(List<WorkerTemplate> templates) => openPrompt(
      PromptOptions(
        title: 'Hire',
        allowEmpty: true,
        worktreeOption: true,
        templates: templates,
        onTemplates: kept.add,
        onSubmit: (text, o) => hired.add((text, o)),
      ),
    );

    open(const [WorkerTemplate(id: 't1', name: 'Log Designer', prompt: '/write-log-design', worktree: true)]);
    await tester.pumpAndSettle();
    expect(find.text('👷 Templates'), findsOneWidget);
    await tester.tap(find.text('Log Designer'));
    await tester.pumpAndSettle();
    expect(find.text('/write-log-design'), findsOneWidget, reason: 'its first task filled in');
    await tester.tap(find.text('Send ✨'));
    await tester.pumpAndSettle();
    expect(hired.last.$1, '/write-log-design');
    expect((hired.last.$2.name, hired.last.$2.worktree), ('Log Designer', true));

    // Not picked: no name, as before.
    open(const []);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '/prepare-qa');
    await tester.tap(find.byKey(const ValueKey('tpl-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tpl-name')), 'QA Prep');
    await tester.tap(find.byKey(const ValueKey('tpl-save')));
    await tester.pumpAndSettle();
    expect([for (final t in kept.last) (t.name, t.prompt)], [('QA Prep', '/prepare-qa')]);
    expect(find.text('QA Prep'), findsOneWidget, reason: 'on the bar, and picked');
    await tester.tap(find.text('Send ✨'));
    await tester.pumpAndSettle();
    expect(hired.last.$2.name, 'QA Prep');

    // ✏️: rename, then remove.
    open(kept.last);
    await tester.pumpAndSettle();
    final id = kept.last.single.id;
    await tester.tap(find.byKey(ValueKey('tpl-$id-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tpl-name')), 'QA Sheet');
    await tester.tap(find.byKey(const ValueKey('tpl-save')));
    await tester.pumpAndSettle();
    expect(kept.last.single.name, 'QA Sheet');
    await tester.tap(find.byKey(ValueKey('tpl-$id-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tpl-delete')));
    await tester.pumpAndSettle();
    expect(kept.last, isEmpty);
    expect(find.text('QA Sheet'), findsNothing);
  });

  test('a template and the message that keeps them survive the wire', () {
    const t = WorkerTemplate(
      id: 't',
      name: 'Rev',
      prompt: '/deep-review',
      agent: AgentChoice(provider: AgentProvider.claude, model: 'opus'),
      worktree: true,
    );
    final back = ClientMsg.parse(const PromptsTemplatesCmd([t]).toJson()) as PromptsTemplatesCmd;
    expect(back.templates.single.toJson(), t.toJson());
    final spawn = ClientMsg.parse(const WorkerSpawnCmd(deskId: 'desk-1', name: 'Rev').toJson()) as WorkerSpawnCmd;
    expect(spawn.name, 'Rev');
    expect(PromptsState.fromJson(const PromptsState(templates: [t]).toJson()).templates.single.name, 'Rev');
  });
}
