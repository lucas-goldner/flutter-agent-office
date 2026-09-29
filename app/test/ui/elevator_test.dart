// The elevator (#127 #126 #139): top floor first with the roof over them, a 💣 for admins that blows
// a floor off the building (and the blast for the people on it), and a new office's walk-through
// with the workspace folder changed right there.

import 'dart:math' as math;

import 'package:agent_office/office/blast.dart';
import 'package:agent_office/ui/elevator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

List<FloorInfo> floors(List<Map<String, dynamic>> js) => [for (final j in js) FloorInfo.fromJson(j)];

void main() {
  test('what the 💣 asks', () {
    final fs = floors([floorJson('a', 'api', workers: 2, people: 1), floorJson('b', 'web')]);
    final (title, body) = blowUpText(fs[0], fs);
    expect(title, 'Blow up api?');
    expect(
      body,
      'Its 2 workers stop. Everyone on it rides the elevator to web. Nothing is deleted: its checkout stays in /w/api, .agent-office folder and all.',
    );
    final solo = floors([floorJson('a', 'api', workers: 1, people: 1, local: true)]);
    final (_, last) = blowUpText(solo[0], solo);
    expect(last, startsWith('Its 1 worker stops. Everyone on it rides the elevator to the lobby. '));
    expect(last, endsWith('just without this floor.'));
  });

  test('the walk-through for a new office', () {
    final steps = setupSteps(
      dir: '~/Workspace',
      custom: false,
      repos: (list: const [], error: 'gh: not logged in', loading: false, at: 1),
    );
    expect(steps.map((s) => s.$2), ['📁 Where projects go', '🐙 GitHub', '🏗️ Your first project']);
    expect(steps[1].$1, isFalse);
    expect(steps[1].$3, contains('gh auth login'));
    final ok = setupSteps(
      dir: '~/code',
      custom: true,
      repos: (
        list: [
          RepoChoice.fromJson({'name': 'acme/api', 'private': false}),
        ],
        error: null,
        loading: false,
        at: 1,
      ),
    );
    expect(ok[0].$1, isTrue);
    expect(ok[1].$3, 'Signed in: 1 repository to pick from.');
  });

  test('the floor you are on blown off the building, and the blast', () {
    final fs = floors([floorJson('b', 'web')]);
    expect(floorBlownUp('a', fs), isTrue);
    expect(floorBlownUp('b', fs), isFalse);
    expect(floorBlownUp(null, fs), isFalse);
    expect(floorBlownUp('@roof', fs), isFalse);

    final b = Blast(random: math.Random(1));
    expect(b.flash, 0);
    expect(b.shake().length, 0);
    b.start();
    b.update(0.06);
    expect(b.flash, closeTo(1, 1e-9));
    expect(b.shake().length, greaterThan(0));
    b.update(0.6);
    expect(b.flash, 0);
    final early = b.strength;
    b.update(0.5);
    expect(b.strength, lessThan(early));
    b.update(3);
    expect(b.active, isFalse);
    expect(b.strength, 0);
  });

  testWidgets('floors top first; the 💣 asks, then blows it up', (tester) async {
    final office = Office()
      ..welcome(floors: [floorJson('f1', 'one'), floorJson('f2', 'two'), floorJson('f3', 'three')]);
    await office.pump(tester, const SizedBox());
    openElevator(office.scope(), ride: (_) {});
    await tester.pump();
    await tester.pump();
    final ys = [
      for (final n in ['three', 'two', 'one']) tester.getTopLeft(find.text(n)).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()), reason: 'the top floor is at the top');
    expect(find.byKey(const ValueKey('ride-roof')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('blow-f2')));
    await tester.pump();
    expect(find.text('Blow up two?'), findsOneWidget);
    await tester.tap(find.text('💣 Blow it up'));
    await tester.pump();
    expect(office.net.sent.whereType<FloorRemoveCmd>().map((c) => c.floor), ['f2']);
  });

  testWidgets('no 💣 for people who are not admins', (tester) async {
    final office = Office()..welcome(floors: [floorJson('f1', 'one')], admin: false);
    await office.pump(tester, const SizedBox());
    openElevator(office.scope(), ride: (_) {});
    await tester.pump();
    expect(find.byKey(const ValueKey('blow-f1')), findsNothing);
  });

  testWidgets('a new office: the steps, and the workspace folder moved right there', (tester) async {
    final office = Office()..welcome(floor: null);
    await office.pump(tester, const SizedBox());
    openElevator(office.scope(), ride: (_) {});
    await tester.pump();
    await tester.pump();
    expect(find.text('📁 Where projects go'), findsOneWidget);
    expect(office.net.sent.whereType<FloorReposCmd>(), hasLength(1));
    await tester.tap(find.byKey(const ValueKey('dir-change')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('dir-input')), '~/code');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(office.net.sent.whereType<FloorProjectsDirCmd>().map((c) => c.dir), ['~/code']);
    // It moved: the editor closes and the note follows.
    office.store.apply(
      ServerMsg.parse({
        't': 'projectsDir',
        'state': {'dir': '~/code', 'custom': true},
      }),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('dir-input')), findsNothing);
    expect(find.textContaining('~/code/<owner>/<repo>'), findsWidgets);
  });
}
