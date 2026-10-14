// The shared part of tests/floorplan.test.ts (the store that saves a plan is the server's), and the
// back office's desks in layout.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test("a sign's text is one tidy line, no longer than a sign", () {
    expect(cleanLabel('a\nb\tc\u0007d'), 'a b c d');
    expect(cleanLabel('🚀' * 40).runes.length, maxLabel);
    expect(cleanLabel(42), '');
  });

  test('only desks get signs: not bean bags, kiosks or the meeting table', () {
    for (final id in ['beanbag-1', 'station-queue', 'meeting-1', 'nope']) {
      expect(canLabel(id), isFalse, reason: id);
    }
    expect(canLabel('desk-1'), isTrue);
    // The back office's desks can have one before they're built, ready for when they are.
    expect(canLabel(wingDesks[0].id), isTrue);
    expect(signColor('#123456'), signColors[0].color);
    expect(signColor(signColors[4].color), signColors[4].color);
    expect(signInk(signColors[3].color), signColors[3].ink);
  });

  test('a broken or tampered plan comes back as what is valid of it', () {
    final plan = cleanPlan({
      'wing': 99,
      'labels': {
        'desk-1': {'text': 'Ops', 'color': 'red'},
        'beanbag-2': {'text': 'x'},
        'desk-2': {'text': '   '},
      },
    });
    expect(plan.wing, Wing.rows);
    expect(plan.labels.keys, ['desk-1']);
    expect(plan.labels['desk-1']!.color, signColors[0].color);
    expect(plan.labels['desk-1']!.by, '?');
    expect(cleanPlan(null).toJson(), emptyPlan.toJson());
    expect(roomToGrow(plan), 0);
    expect(roomToGrow(emptyPlan), Wing.rows);
  });

  test('the back office adds two desks a row, numbered on from the room', () {
    expect(wingDesks.length, 2 * Wing.rows);
    expect(wingDesks.first.id, 'desk-${desks.length + 1}');
    expect([for (final d in rowDesks(1)) d.id], ['desk-${desks.length + 1}', 'desk-${desks.length + 2}']);
    expect(builtDesks(0).length, desks.length);
    expect(builtDesks(Wing.rows).length, desks.length + 2 * Wing.rows);
    expect(wingLevel(1.7), 1);
    expect(wingLevel(-3), 0);
    expect(wingLevel('2'), 0);
    expect(wingMinZ(2), Floor.minZ - 2 * Wing.row);
    expect(inWing(15, Floor.minZ - 1, 1), isTrue);
    expect(inWing(15, Floor.minZ - 1, 0), isFalse);
    expect(plantsAt(1).length, lessThan(plants.length));
    for (final d in wingDesks) {
      expect(deskById[d.id], same(d));
    }
  });

  test('new workers take the back office desks once it is built, before any bean bag', () {
    final taken = {for (final d in desks) d.id};
    expect(nextFreeSeat(taken.contains)?.id, beanbags[0].id, reason: 'with no back office, the bean bags come out');
    expect(nextFreeSeat(taken.contains, 1)?.id, wingDesks[0].id);
    expect(beanbagsOut(taken.contains).length, 1);
    expect(beanbagsOut(taken.contains, 1).length, 0);
    for (final d in builtDesks(1)) {
      taken.add(d.id);
    }
    expect(beanbagsOut(taken.contains, 1).length, 1);
    expect(nextFreeSeat(taken.contains, 1)?.id, beanbags[0].id);
  });
}
