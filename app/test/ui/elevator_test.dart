// The elevator (#127 #126 #139): top floor first with the roof over them, a 💣 for admins that blows
// a floor off the building (and the blast for the people on it), and a new office's walk-through
// with the workspace folder changed right there.

import 'dart:math' as math;

import 'package:agent_office/office/blast.dart';
import 'package:agent_office/ui/elevator.dart';
import 'package:agent_office/ui/window_parts.dart' show BoxInput;
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

  testWidgets('the garage under floor 1, and your floor to ride back up to from down there (#169)', (tester) async {
    final office = Office()..welcome(floors: [floorJson('f1', 'one'), floorJson('f2', 'two')], floor: 'f2');
    await office.pump(tester, const SizedBox());
    final rides = <String>[];
    var down = false;
    openElevator(office.scope(), ride: rides.add, downstairs: () => down);
    await tester.pump();
    await tester.pump();
    final garage = find.byKey(const ValueKey('ride-garage'));
    expect(garage, findsOneWidget);
    expect(tester.getTopLeft(garage).dy, greaterThan(tester.getTopLeft(find.text('one')).dy), reason: 'under floor 1');
    expect(find.text('you are here'), findsOneWidget);
    await tester.tap(garage);
    await tester.pump();
    expect(rides, [garageStop]);

    // Down there: the garage is where you are, and your floor is one to go back up to.
    down = true;
    openElevator(office.scope(), ride: rides.add, downstairs: () => down);
    await tester.pump();
    await tester.pump();
    expect(find.text('Garage · you are here'), findsOneWidget);
    expect(find.text('your floor'), findsOneWidget);
    await tester.tap(find.text('two'));
    await tester.pump();
    expect(rides, [garageStop, 'f2']);
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

  testWidgets('a floor being cloned shows how far it has got, and ⏹️ stops it', (tester) async {
    final office = Office()
      ..welcome(
        floors: [
          floorJson('f1', 'one'),
          {
            ...floorJson('f2', 'big'),
            'cloning': true,
            'clone': {'step': 'Receiving objects', 'percent': 42, 'detail': '231.4 MiB · 1.5 MiB/s'},
          },
        ],
      );
    await office.pump(tester, const SizedBox());
    openElevator(office.scope(), ride: (_) {});
    await tester.pump();
    await tester.pump();
    expect(find.text('⏳ Receiving objects 42%'), findsOneWidget);
    expect(find.text('acme/big · 231.4 MiB · 1.5 MiB/s'), findsOneWidget);
    expect(find.byType(CloneBar), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stop-f2')));
    await tester.pump();
    await tester.tap(find.text('⏹️ Stop cloning'));
    await tester.pump();
    expect(office.net.sent.whereType<FloorCancelCmd>().map((c) => c.floor), ['f2']);
  });

  testWidgets('waiting on a clone: the floor list says how it ended, even with no answer', (tester) async {
    final office = Office()..welcome(floor: null);
    await office.pump(tester, const SizedBox());
    String? rode;
    openElevator(office.scope(), ride: (f) => rode = f);
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.widgetWithText(BoxInput, 'Search your repositories, or type owner/name'), 'acme/big');
    await tester.pump();
    await tester.tap(find.text('🛗 Add acme/big'));
    await tester.pump();
    expect(office.net.sent.whereType<FloorAddCmd>().single.repo, 'acme/big');
    expect(elevatorWaitingOn('acme/big'), isTrue);
    expect(find.text('⏳ Asking GitHub about acme/big…'), findsOneWidget);
    void floors(bool cloning) => office.store.apply(
      ServerMsg.parse({
        't': 'floors',
        'floors': [
          floorJson('f1', 'one'),
          {...floorJson('f2', 'big'), 'cloning': cloning},
        ],
      }),
    );
    floors(true);
    await tester.pump();
    expect(find.text('⏳ Cloning acme/big into ~/Workspace/acme/big'), findsOneWidget);
    // The office restarted mid-clone: no floor.added, but the floor is there now.
    floors(false);
    await tester.pump();
    expect(rode, 'f2');
    expect(elevatorWaitingOn('acme/big'), isFalse);
    await tester.pump(const Duration(seconds: 61));
  });
}
