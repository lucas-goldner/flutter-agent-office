// The quiet HUD (#100): which actions sit on the top bar, the ☰ menu with its pins and panel
// switches, the floors dropdown (#94), and the worker counts that leave out the board agents.

import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/floormenu.dart';
import 'package:agent_office/ui/menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

WorkerInfo worker(
  String id, {
  String desk = 'desk-1',
  String status = 'working',
  bool acked = true,
  int at = 0,
  int? since,
}) =>
    WorkerInfo.fromJson({...workerJson(id, desk: desk, status: status, acked: acked, at: at), 'waitingSince': ?since});

void main() {
  group('rules', () {
    var sharing = false;
    final ran = <String>[];
    final actions = [
      HudAction(id: 'issues', icon: '📌', label: 'Issues', section: HudSection.open, run: () => ran.add('issues')),
      HudAction(
        id: 'share',
        icon: '🖥️',
        label: 'Share',
        section: HudSection.together,
        status: () => sharing,
        chip: () => 'Sharing',
        run: () {},
      ),
      HudAction(id: 'team', icon: '👥', label: 'Invite', section: HudSection.together, shown: () => false, run: () {}),
      HudAction(id: 'help', icon: '❓', label: 'Controls', section: HudSection.office, key: 'H', run: () {}),
    ];

    test('the dock has what you pinned and what needs you, in the menu order', () {
      final s = Settings();
      expect(dockActions(actions, s), isEmpty);
      s.pins = togglePin(s.pins, 'help');
      s.pins = togglePin(s.pins, 'team');
      expect(dockActions(actions, s).map((a) => a.id), ['help'], reason: 'Invite is not offered');
      sharing = true;
      expect(dockActions(actions, s).map((a) => a.id), ['share', 'help']);
      expect(dockChip(actions[1], s), 'Sharing');
      s.pins = togglePin(s.pins, 'share');
      expect(dockChip(actions[1], s), isNull, reason: 'a pinned one is just its icon');
      s.pins = togglePin(s.pins, 'share');
      expect(s.pins, ['help', 'team']);
      sharing = false;
    });

    test('tooltips and sections', () {
      expect(actions[3].tooltip, 'Controls (H)');
      final blocked = HudAction(
        id: 'voice',
        icon: '🎙️',
        label: 'Join voice',
        section: HudSection.together,
        blocked: () => 'Needs HTTPS',
        run: () {},
      );
      expect(blocked.tooltip, 'Needs HTTPS');
      final sections = menuSections(actions);
      expect(sections.map((e) => e.$1), HudSection.values);
      expect(sections[1].$2.map((a) => a.id), ['share']);
    });

    test('worker counts leave out the board agents at their kiosks', () {
      final ws = [worker('1'), worker('2', desk: 'station-issues'), worker('3', desk: 'desk-2', status: 'needs_input')];
      expect(hiredCount(ws), 2);
      expect(workersTitle(ws), '2 workers on this floor, 1 waiting on someone');
      expect(workersTitle([worker('2', desk: 'station-queue')]), 'No workers on this floor yet');
      expect(workersTitle([worker('1')]), '1 worker on this floor');
    });

    test('who is waiting, longest first, and how the top bar says it', () {
      final ws = [
        worker('a', status: 'done', acked: false, since: 30),
        worker('b', status: 'needs_input', since: 10),
        worker('c', status: 'done', acked: true),
        worker('d', status: 'needs_input', at: 5),
      ];
      expect(waitingInOrder(ws).map((w) => w.id), ['d', 'b', 'a']);
      expect(waitingLabel(waitingInOrder(ws)), '🙋 2 waiting · ✅ 1 done');
      expect(waitingLabel([ws[0]]), '✅ 1 done');
    });

    test('the People chip shows once you are not alone', () {
      final s = Settings();
      expect(peopleChipShown(1, s), isFalse);
      expect(peopleChipShown(2, s), isTrue);
      s.hud[HudPanel.people] = true;
      expect(peopleChipShown(1, s), isTrue);
    });

    test('the floor list reads top floor first, with how far each is', () {
      final floors = [
        for (final n in ['one', 'two', 'three']) FloorInfo.fromJson(floorJson(n, n)),
      ];
      final rows = floorRows(floors, 'two');
      expect(rows.map((r) => r.number), [3, 2, 1]);
      expect(rows.map((r) => r.sub), ['⬆ 1 floor up', 'you are here', '⬇ 1 floor down']);
      expect(floorRows(floors, null).first.sub, 'acme/three');
    });
  });

  group('widgets', () {
    testWidgets('☰ opens the menu; a pin puts an action on the top bar; a switch shows a panel', (tester) async {
      final office = Office()..welcome();
      var opened = 0;
      final saved = <int>[];
      final prefs = HudPrefs(settings: office.settings, save: () => saved.add(1))
        ..actions = [
          HudAction(
            id: 'issues',
            icon: '📌',
            label: 'Issues',
            section: HudSection.open,
            count: () => 3,
            run: () => opened++,
          ),
          HudAction(id: 'settings', icon: '⚙️', label: 'Settings', section: HudSection.office, run: () {}),
        ];
      final menuKey = GlobalKey();
      await office.pump(
        tester,
        Align(
          alignment: Alignment.topRight,
          child: Dock(
            prefs: prefs,
            menuKey: menuKey,
            onMenu: () => toggleHudMenu(prefs, anchor: menuKey),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('dock-issues')), findsNothing);
      expect(find.byKey(const ValueKey('dock-workers')), findsOneWidget);

      await tester.tap(find.byKey(menuKey));
      await tester.pump();
      expect(find.byKey(const ValueKey('hud-menu')), findsOneWidget);
      expect(find.text('Issues'), findsOneWidget);
      expect(find.text('Show on screen'.toUpperCase()), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pin-issues')));
      await tester.pump();
      expect(office.settings.pins, ['issues']);
      expect(find.byKey(const ValueKey('dock-issues')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-workers')));
      await tester.pump();
      expect(office.settings.hud[HudPanel.workers], isTrue);
      expect(saved, hasLength(2));

      // Running an action closes the menu first.
      await tester.tap(find.byKey(const ValueKey('menu-issues')));
      await tester.pump();
      expect(opened, 1);
      expect(find.byKey(const ValueKey('hud-menu')), findsNothing);
      expect(hudMenuOpen(), isFalse);

      // Tab closes it like Esc.
      await tester.tap(find.byKey(menuKey));
      await tester.pump();
      expect(hudMenuOpen(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(hudMenuOpen(), isFalse);

      // A click beside it closes it too.
      await tester.tap(find.byKey(menuKey));
      await tester.pump();
      await tester.tapAt(const Offset(20, 800));
      await tester.pump();
      expect(hudMenuOpen(), isFalse);
    });

    testWidgets('the Workers chip counts the hired ones and turns its panel on', (tester) async {
      final office = Office()..welcome();
      for (final w in [worker('1'), worker('2', desk: 'station-pulls')]) {
        office.store.apply(WorkerUpdateMsg(w));
      }
      final prefs = HudPrefs(settings: office.settings);
      await office.pump(tester, Dock(prefs: prefs, onMenu: () {}));
      final chip = find.byKey(const ValueKey('dock-workers'));
      expect(find.descendant(of: chip, matching: find.text('1')), findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      expect(prefs.panel(HudPanel.workers), isTrue);
    });

    testWidgets('the floor list goes to a floor, or the elevator to add one', (tester) async {
      final office = Office()..welcome(floors: [floorJson('f1', 'one'), floorJson('f2', 'two', waiting: 2)]);
      final went = <String>[];
      var elevator = 0;
      final opts = FloorMenuOptions(go: went.add, elevator: () => elevator++, roof: () => went.add('roof'));
      await office.pump(
        tester,
        Builder(
          builder: (context) =>
              TextButton(onPressed: () => toggleFloorMenu(office.store, opts), child: const Text('project')),
        ),
      );
      await tester.tap(find.text('project'));
      await tester.pump();
      expect(find.text('🏢 2 floors'), findsOneWidget);
      expect(find.text('🙋 2'), findsOneWidget);
      // Here is no place to go.
      await tester.tap(find.byKey(const ValueKey('floor-f1')));
      await tester.pump();
      expect(went, isEmpty);
      await tester.tap(find.byKey(const ValueKey('floor-f2')));
      await tester.pump();
      expect(went, ['f2']);
      expect(floorMenuOpen(), isFalse);
      await tester.tap(find.text('project'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('floor-elevator')));
      await tester.pump();
      expect(elevator, 1);
    });
  });
}
