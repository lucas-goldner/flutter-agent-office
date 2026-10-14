// ⚙️ Settings' new parts (#101 #106 #92 #129 #141 #137): the workspace folder, the holiday theme,
// the worker limit, push to talk, leave-on-merge, the default worker, and the prompt editor.

import 'package:agent_office/notify.dart';
import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/prompts.dart';
import 'package:agent_office/ui/settings.dart';
import 'package:agent_office/ui/worker_limit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      final needs = promptWarnings(promptIds.firstWhere((id) => prompts[id]!.needs.contains('file')), 'Wait.');
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

  /// Scrolls the pane to [f] and taps it.
  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
  }

  Future<void> pane(WidgetTester tester, SettingsPane p) async {
    await tester.tap(find.byKey(ValueKey('settings-tab-${p.name}')));
    await tester.pump();
  }

  testWidgets('an admin sets the building’s settings', (tester) async {
    final changes = <Settings>[];
    final office = await openIt(tester, changes: changes);
    await pane(tester, SettingsPane.sound);
    await tap(tester, find.text('✋ Push to talk'));
    await tester.pump();
    expect(changes.last.pushToTalk, isTrue);

    await pane(tester, SettingsPane.building);
    await tap(tester, find.text('🎄 Christmas'));
    await tester.ensureVisible(find.byKey(const ValueKey('dir-input')));
    await tester.enterText(find.byKey(const ValueKey('dir-input')), '~/code');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await pane(tester, SettingsPane.workers);
    await tap(tester, find.text('🏠 Go home by themselves'));
    await tester.ensureVisible(find.byKey(const ValueKey('limit-input')));
    await tester.enterText(find.byKey(const ValueKey('limit-input')), '5');
    await tap(tester, find.text('Set limit'));
    await tester.pump();
    final sent = office.net.sent;
    expect(sent.whereType<ThemeSetCmd>().single.pick, ThemePick.christmas);
    expect(sent.whereType<LeaveOnMergeSetCmd>().single.on, isTrue);
    expect(sent.whereType<MachineLimitCmd>().single.limit, 5);
    expect(sent.whereType<FloorProjectsDirCmd>().single.dir, '~/code');

    // The default worker: Claude Code on Opus.
    await tap(tester, find.text('Default (--agent-args)'));
    await tester.pumpAndSettle();
    await tap(tester, find.text('Opus 5.5'));
    await tester.pumpAndSettle();
    await tap(tester, find.byKey(const ValueKey('agent-save')));
    await tester.pump();
    final agent = sent.whereType<PromptsAgentCmd>().single.choice!;
    expect((agent.provider, agent.model), (AgentProvider.claude, 'opus'));
  });

  testWidgets('everyone else reads them', (tester) async {
    await openIt(tester, admin: false);
    await pane(tester, SettingsPane.workers);
    expect(find.byKey(const ValueKey('limit-input')), findsNothing);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('📝 Read the prompts…'), findsOneWidget);
  });

  testWidgets('the prompt editor: rewrite one, put in a placeholder, save', (tester) async {
    final office = await openIt(tester);
    await pane(tester, SettingsPane.workers);
    await tap(tester, find.byKey(const ValueKey('open-prompts')));
    await tester.pump();
    await tester.pump();
    expect(find.text('🤖 Hand to a worker'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('prompt-text')), 'Fix #');
    await tester.pump();
    expect(find.text('● Not saved yet'), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('var-number')));
    await tester.pump();
    await tap(tester, find.text('Save').last);
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

  testWidgets('categories down the side: arrow keys, who each card is for, back where it was', (tester) async {
    lastSettingsPane = SettingsPane.you;
    final changes = <Settings>[];
    await openIt(tester, changes: changes);
    expect(find.text('🧍 You'), findsOneWidget);
    expect(find.text('Camera view'), findsOneWidget);
    expect(find.text('Just you'), findsOneWidget);
    await pane(tester, SettingsPane.you);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('🔊 Sound & voice'), findsOneWidget);
    await tester.tap(find.text('🔁 Keep reminding me'));
    await tester.tap(find.text('Off').first);
    await tester.pump();
    expect(changes.map((s) => s.needsYouSound).toList(), contains(NeedsYouSound.remind));
    expect(changes.last.pageTurns, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(find.text('🤖 Workers'), findsWidgets, reason: 'up from the top goes round to the bottom');
    expect(lastSettingsPane, SettingsPane.workers);
    expect(find.text('Everyone'), findsWidgets);
  });

  test('a card of your own goes in among the office’s', () {
    final cards = SettingsCards()
      ..add(SettingsPane.building, id: 'theme', order: 20, (_) => const SizedBox())
      ..add(SettingsPane.building, id: 'map', order: 5, (_) => const SizedBox(), topics: const [Topic.floor])
      ..add(SettingsPane.you, id: 'x', (_) => null);
    expect(cards.of(SettingsPane.building).map((c) => c.id), ['map', 'theme']);
    cards.add(SettingsPane.building, id: 'theme', order: 1, (_) => const SizedBox());
    expect(cards.of(SettingsPane.building).map((c) => c.id), ['theme', 'map'], reason: 'the same id replaces');
    expect(cards.topics, {Topic.floor});
    expect(stepPane(SettingsPane.you, -1), SettingsPane.workers);
    expect(stepPane(SettingsPane.workers, 1), SettingsPane.you);
  });

  test('the new settings are remembered', () {
    final s = Settings.fromJson({'pageTurns': false, 'needsYouSound': 'remind'});
    expect((s.pageTurns, s.needsYouSound), (false, NeedsYouSound.remind));
    final back = Settings.fromJson(s.toJson());
    expect((back.pageTurns, back.needsYouSound), (false, NeedsYouSound.remind));
    expect(Settings.fromJson({'needsYouSound': 'loud'}).needsYouSound, NeedsYouSound.once);
  });
}
