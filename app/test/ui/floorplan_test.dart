// Signs over the desks and the back office (#183): the sign dialog (L at a desk), the back office's
// (E at its sign), how the signs hang and say their words, and where the back office reaches.

import 'package:agent_office/office/controller.dart';
import 'package:agent_office/ui/floorplan.dart';
import 'package:agent_office/ui/whereabouts.dart';
import 'package:agent_office/walkto.dart';
import 'package:agent_office/world/desk_signs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/floorplan.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';
import 'whereabouts_test.dart' show peer;

void main() {
  testWidgets('L at a desk: a sign with an idea and a colour goes up, and an old one comes down', (tester) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox());
    openDeskLabel(office.scope(), 'desk-1');
    await tester.pump();
    expect(find.text('🪧 Sign over Desk 1'), findsOneWidget);
    // Nothing to hang yet.
    expect(
      tester
          .widget<GestureDetector>(
            find
                .descendant(of: find.byKey(const ValueKey('sign-submit')), matching: find.byType(GestureDetector))
                .first,
          )
          .onTap,
      isNull,
    );
    await tester.tap(find.text('Code cleanup'));
    await tester.tap(find.byKey(const ValueKey('swatch-Green')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sign-submit')));
    await tester.pump();
    final sent = office.net.sent.whereType<DeskLabelCmd>().single;
    expect(sent.deskId, 'desk-1');
    expect(sent.text, 'Code cleanup');
    expect(sent.color, '#06d6a0');

    // With a sign up: emptied, the button takes it down.
    office.store.apply(
      PlanMsg(
        FloorPlan(
          labels: {'desk-1': DeskLabel(text: 'Ops', color: '#ef476f', by: 'Ada', at: 1)},
        ),
      ),
    );
    openDeskLabel(office.scope(), 'desk-1');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('Take it down'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('sign-submit')));
    await tester.pump();
    expect(office.net.sent.whereType<DeskLabelCmd>().last.text, '');
  });

  testWidgets("E at the back office's sign knocks through, and walls the last row up only once nobody's there", (
    tester,
  ) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox());
    openExpand(office.scope());
    await tester.pump();
    expect(find.text('🔨 Knock through (+2 desks)'), findsOneWidget);
    expect(find.byKey(const ValueKey('shrink')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('expand')));
    await tester.pump();
    expect(office.net.sent.whereType<FloorExpandCmd>(), hasLength(1));

    office.store.apply(const PlanMsg(FloorPlan(wing: 1)));
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': workerJson('w1', desk: rowDesks(1).first.id)}));
    openExpand(office.scope());
    await tester.pump();
    expect(find.textContaining('built out 1 of ${Wing.rows} rows'), findsOneWidget);
    expect(find.textContaining('send them home before walling that row up'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shrink')));
    await tester.pump();
    expect(office.net.sent.whereType<FloorShrinkCmd>(), isEmpty, reason: 'someone is at a desk in that row');
  });

  test("a pair's two signs hang back to back, and one alone says it on its back too", () {
    final a = desks.first;
    final b = deskPartner[a.id];
    expect(b, isNotNull, reason: 'desks come in back-to-back pairs');
    expect(deskPartner[b], a.id);
    for (final row in [1, 2]) {
      final [x, y] = rowDesks(row);
      expect(deskPartner[x.id], y.id, reason: 'the back office is pairs too');
    }
    bool built(DeskDef _) => true;
    final one = {a.id: const DeskLabel(text: 'Ops', color: '#2b2d42', by: 'Ada', at: 0)};
    expect(DeskSigns.twoSided(a.id, one, built), isTrue);
    final both = {...one, b!: const DeskLabel(text: 'Docs', color: '#2b2d42', by: 'Ada', at: 0)};
    expect(DeskSigns.twoSided(a.id, both, built), isFalse);
    // A back office desk whose partner isn't built: nothing behind it to read it from.
    final [w1, w2] = rowDesks(1);
    expect(DeskSigns.twoSided(w1.id, {w1.id: one.values.first}, (d) => d.id != w2.id), isFalse);
  });

  testWidgets('a long sign goes on two lines, a short one big on one', (tester) async {
    final short = fitSign('Ops', 900, 270);
    expect(short.lines, ['Ops']);
    final long = fitSign('Code cleanup crew', 900, 270);
    expect(long.lines, hasLength(2));
    expect(long.size, lessThan(short.size));
  });

  test('standing past where the back office goes now, and walking through it', () {
    final inRow2 = (x: (Wing.minX + Wing.maxX) / 2, y: 0.0, z: wingRowZ(2));
    expect(OfficeController.pastTheWing(inRow2, 2), isFalse);
    expect(OfficeController.pastTheWing(inRow2, 1), isTrue);
    expect(OfficeController.pastTheWing((x: 0, y: 0, z: 0), 0), isFalse, reason: 'in the room');
    // A walk to the back row goes in through where the north wall was, not round outside.
    final way = wayTo((x: 10.0, y: 0.0, z: 0.0), (x: inRow2.x, y: 0.0, z: inRow2.z - 0.4), 2);
    expect(way, isNotEmpty);
    expect(way.every((c) => c.x > Floor.minX && c.x < Floor.maxX), isTrue);
    expect(way.last.z, lessThan(Floor.minZ));
    expect(whereabouts(peer(inRow2.x, inRow2.z)), '🏗️ in the back office');
  });
}
