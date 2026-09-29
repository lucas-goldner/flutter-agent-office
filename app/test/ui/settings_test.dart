// ⚙️ Settings' new parts (#101 #106 #92 #129 #141 #137): the workspace folder, the holiday theme,
// the worker limit, push to talk, leave-on-merge, the default worker, and the prompt editor.

import 'package:agent_office/notify.dart';
import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/prompts.dart';
import 'package:agent_office/ui/settings.dart';
import 'package:agent_office/ui/worker_limit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/prompts.dart';
import 'package:office_shared/protocol.dart';

import '../notify_test.dart' show FakeApi;
import 'harness.dart';

MachineState machine(Map<String, dynamic> j) =>
    MachineState.fromJson({'cpu': 0, 'cores': 8, 'memUsed': 1, 'memTotal': 2, 'workers': 3, ...j});

void main() {
  group('words', () {
    test('the worker limit', () {
      expect(
        limitNote(machine({}), admin: true),
        startsWith('No limit: the office hires a worker for every free seat. 3 are here now'),
      );
      expect(
        limitNote(
          machine({
            'limit': 1,
            'ceiling': 4,
            'set': {'limit': 1, 'by': 'Ada', 'at': 0},
          }),
          admin: false,
          ago: (_) => 'just now',
        ),
        'At most 1 worker at once, across every floor (3 now), shells and board agents too. Hiring past that is refused. '
        "Set by Ada just now. The office was started with --max-workers 4, so it can't go any higher. Admins can change it.",
      );
      expect(parseLimit(' 6 '), 6);
      expect(parseLimit('0'), isNull);
      expect(parseLimit('x'), isNull);
      expect(officeFull(machine({'limit': 3})), isTrue);
      expect(officeFull(machine({'limit': 4})), isFalse);
      expect(queueFullNote(machine({'limit': 3}), 0), isNull);
      expect(queueFullNote(machine({'limit': 3}), 2), startsWith('⏸ The office is at its limit of 3 workers'));
      expect(pressureNote(machine({'pressure': 'memory is 93% used'})), contains('memory is 93% used'));
    });

    test('the theme and leave-on-merge notes', () {
      expect(
        themeNote(const ThemeState()),
        'No decorations up right now. By the calendar it’s Halloween through October and Christmas through December. It’s the same for everyone in the building.',
      );
      expect(
        themeNote(
          const ThemeState(pick: ThemePick.christmas, active: HolidayTheme.christmas, by: 'Bo', at: 1),
          ago: (_) => '2m ago',
        ),
        endsWith('snowing outside. It’s the same for everyone in the building, set by Bo 2m ago.'),
      );
      expect(leaveOnMergeNote(const LeaveOnMergeState(on: true)), startsWith('Once a worker’s pull request merges'));
    });

    test('prompt warnings', () {
      expect(promptWarnings('issue.work', prompts['issue.work']!.text), isEmpty);
      expect(promptWarnings('issue.work', '  '), ['It can’t be empty: write something, or put the default back.']);
      expect(promptWarnings('issue.ask', ''), isEmpty, reason: 'it may be left empty');
      expect(promptWarnings('issue.work', 'Do {{thing}}'), [
        '{{thing}} isn’t filled in here, so it’s sent just as it’s written.',
      ]);
      final needs = promptWarnings(promptIds.firstWhere((id) => prompts[id]!.needs.isNotEmpty), 'Wait.');
      expect(needs.single, startsWith('The office counts on {{file}}'));
      expect(normPrompt(' a\r\nb \n'), 'a\nb');
    });
  });

  Future<Office> openIt(WidgetTester tester, {bool admin = true, List<Settings>? changes}) async {
    final office = Office()..welcome(admin: admin);
    await office.pump(tester, const SizedBox(), size: const Size(1400, 3000));
    openSettings(
      office.scope(),
      settings: office.settings,
      onChange: (s) => changes?.add(s),
      onCharacter: () {},
      previewSound: () {},
      notifier: DesktopNotifier(enabled: () => true, openWorker: (_) {}, api: FakeApi()),
      onSignOut: () {},
    );
    await tester.pump();
    await tester.pump();
    return office;
  }

  testWidgets('an admin sets the building’s settings', (tester) async {
    final changes = <Settings>[];
    final office = await openIt(tester, changes: changes);
    await tester.tap(find.text('✋ Push to talk'));
    await tester.pump();
    expect(changes.last.pushToTalk, isTrue);

    await tester.tap(find.text('🎄 Christmas'));
    await tester.tap(find.text('🏠 Go home by themselves'));
    await tester.enterText(find.byKey(const ValueKey('limit-input')), '5');
    await tester.tap(find.text('Set limit'));
    await tester.enterText(find.byKey(const ValueKey('dir-input')), '~/code');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    final sent = office.net.sent;
    expect(sent.whereType<ThemeSetCmd>().single.pick, ThemePick.christmas);
    expect(sent.whereType<LeaveOnMergeSetCmd>().single.on, isTrue);
    expect(sent.whereType<MachineLimitCmd>().single.limit, 5);
    expect(sent.whereType<FloorProjectsDirCmd>().single.dir, '~/code');

    // The default worker: Claude Code on Opus.
    await tester.tap(find.text('Default (--agent-args)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Opus'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-save')));
    await tester.pump();
    final agent = sent.whereType<PromptsAgentCmd>().single.choice!;
    expect((agent.provider, agent.model), (AgentProvider.claude, 'opus'));
  });

  testWidgets('everyone else reads them', (tester) async {
    await openIt(tester, admin: false);
    expect(find.byKey(const ValueKey('limit-input')), findsNothing);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('📝 Read the prompts…'), findsOneWidget);
  });

  testWidgets('the prompt editor: rewrite one, put in a placeholder, save', (tester) async {
    final office = await openIt(tester);
    await tester.tap(find.byKey(const ValueKey('open-prompts')));
    await tester.pump();
    await tester.pump();
    expect(find.text('🤖 Hand to a worker'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('prompt-text')), 'Fix #');
    await tester.pump();
    expect(find.text('● Not saved yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('var-number')));
    await tester.pump();
    await tester.tap(find.text('Save').last);
    await tester.pump();
    final set = office.net.sent.whereType<PromptsSetCmd>().single;
    expect((set.id, set.text), ('issue.work', 'Fix #{{number}}'));
    // Saved: the draft is done with.
    office.store.apply(
      ServerMsg.parse({
        't': 'prompts',
        'state': {
          'custom': {
            'issue.work': {'text': 'Fix #{{number}}', 'by': 'Ada', 'at': DateTime.now().millisecondsSinceEpoch},
          },
        },
      }),
    );
    await tester.pump();
    expect(find.text('✎ Rewritten by Ada just now'), findsOneWidget);
    expect(officePrompt(office.store, 'issue.work', {'number': 7}), 'Fix #7');
  });
}
