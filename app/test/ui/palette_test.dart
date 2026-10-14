// The command palette's window (ui/palette.ts): typing narrows the list, the arrows choose, Enter opens it
// and Shift+Enter walks there first. The ranking itself is office_shared's (packages/office_shared/test).

import 'package:agent_office/office/palette_entries.dart';
import 'package:agent_office/ui/modal.dart';
import 'package:agent_office/ui/palette.dart';
import 'package:agent_office/world/collider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void main() {
  testWidgets('type, choose, Enter opens; Shift+Enter walks there first', (tester) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox());
    final did = <String>[];
    List<PaletteRow> rows() => [
      PaletteRow(
        icon: '🧑‍💻',
        kind: 'Worker',
        title: 'Ada',
        detail: 'Fix Login Redirect · Desk 7',
        open: () => did.add('open Ada'),
        walk: () => did.add('walk Ada'),
      ),
      PaletteRow(
        icon: '⚙️',
        kind: 'Action',
        title: 'Settings',
        keywords: const ['preferences'],
        open: () => did.add('settings'),
      ),
      PaletteRow(icon: '📌', kind: 'Board', title: 'Issues board', open: () => did.add('issues')),
    ];
    togglePalette(rows);
    await tester.pump();
    await tester.pump();
    expect(paletteOpen(), isTrue);
    expect(find.text('Settings'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('palette-input')), 'login');
    await tester.pump();
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Ada'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(did, ['walk Ada']);
    expect(paletteOpen(), isFalse);

    togglePalette(rows);
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('palette-input')), 'pref');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(did.last, 'settings');

    togglePalette(rows);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(did.last, 'issues');
    // Ctrl+K again puts it away.
    togglePalette(rows);
    await tester.pump();
    togglePalette(rows);
    await tester.pump();
    expect(ModalStack.instance.open, isFalse);
  });

  test('the office’s entries: workers, actions, boards, issues and PRs, teammates', () {
    final office = Office()..welcome();
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': workerJson('w1')}));
    final walked = <String>[];
    final opened = <String>[];
    final host = PaletteHost(
      store: office.store,
      you: () => (x: 0, z: 0),
      interactables: () => [Interactable(kind: InteractKind.issues, x: 3, z: 4, radius: 1)],
      walkThen: (at, what, then, {face}) {
        walked.add(what);
        then();
      },
      openTerminal: (id) => opened.add('terminal $id'),
      hireAt: (d) => opened.add('hire $d'),
      showQueue: () => opened.add('queue'),
      showSettings: () => opened.add('settings'),
      showSearch: () => opened.add('search'),
      invite: null,
      startHanging: () => opened.add('hang'),
      openBoard: (k) => opened.add('board ${k.name}'),
      openIssue: (i) => opened.add('issue ${i.number}'),
      openPull: (p) => opened.add('pull ${p.number}'),
      walkTo: (id) => opened.add('walk to $id'),
    );
    final entries = paletteEntries(host);
    final titles = entries.map((e) => e.title).toList();
    expect(titles.first, 'Ww1');
    expect(titles, containsAll(['Hire a worker', 'Open the task queue', 'Settings', 'Issues board', 'PR board']));
    expect(titles, isNot(contains('Invite people')));
    entries.firstWhere((e) => e.title == 'Issues board').walk!();
    expect(walked, ['the Issues board']);
    expect(opened.last, 'board issues');
    expect(entries.firstWhere((e) => e.title == 'PR board').walk, isNull, reason: 'no PR board on this floor');
    entries.first.open();
    expect(opened.last, 'terminal w1');
  });
}
