// Every window can be closed (#163) and a name can be made up (#166): the welcome elevator closes with Esc
// but not a stray click, and the first character pick goes in under the suggested name when skipped.

import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/character.dart';
import 'package:agent_office/ui/elevator.dart';
import 'package:agent_office/ui/modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  testWidgets('the welcome elevator closes with Esc, not a stray click', (tester) async {
    final office = Office()..welcome(floor: null);
    await office.pump(tester, const SizedBox());
    openElevator(office.scope(), ride: (_) {});
    await tester.pump();
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(elevatorPanelOpen(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(elevatorPanelOpen(), isFalse);
  });

  testWidgets('skipping the first pick goes in under the made-up name', (tester) async {
    final office = Office()..welcome();
    office.store.profile = Profile(name: 'Guest', color: '#ff8a5b', look: office.store.profile.look);
    await office.pump(tester, const SizedBox(), size: const Size(1400, 1200));
    Profile? saved;
    openCharacter(office.scope(), first: true, onSave: (p) => saved = p);
    await tester.pump();
    await tester.pump();
    final box = tester.widget<TextField>(
      find.descendant(of: find.byKey(const ValueKey('name-input')), matching: find.byType(TextField)),
    );
    expect(box.controller!.text, isEmpty, reason: 'Guest isn’t a name to keep');
    final suggested = box.decoration!.hintText!;
    expect(suggested, matches(RegExp(r'^\w+ \w+$')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(ModalStack.instance.open, isFalse);
    expect(saved?.name, suggested);
  });

  testWidgets('🎲 deals another name; blank saves the one suggested', (tester) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox(), size: const Size(1400, 1200));
    Profile? saved;
    openCharacter(office.scope(), onSave: (p) => saved = p);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reroll')));
    await tester.pump();
    final box = tester.widget<TextField>(
      find.descendant(of: find.byKey(const ValueKey('name-input')), matching: find.byType(TextField)),
    );
    final rolled = box.controller!.text;
    expect(rolled, box.decoration!.hintText);
    await tester.enterText(find.byKey(const ValueKey('name-input')), '   ');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(saved?.name, rolled);
  });
}
