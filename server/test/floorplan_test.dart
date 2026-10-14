import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/floorplan.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The server's side of upstream's tests/floorplan.test.ts: signs over desks and the back office.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('agent-office-floorplan-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('signs go up over desks, get changed and come down, and stay across restarts', () {
    final plan = FloorPlanStore(dir.path, now: () => 0);
    final hung = plan.label('desk-3', '  Code   cleanup ', signColors[4].color, 'Ada').done!;
    expect(hung.label, isNotNull);
    expect(hung.old, isNull);
    expect(plan.state().labels['desk-3']!.toJson(), {
      'text': 'Code cleanup',
      'color': signColors[4].color,
      'by': 'Ada',
      'at': 0,
    });
    // A color that isn't one of the signs' is the first one.
    final changed = plan.label('desk-3', 'Operations', '#123456', 'Bo').done!;
    expect(changed.old?.text, 'Code cleanup');
    expect(plan.state().labels['desk-3']!.color, signColors[0].color);
    // Across a restart.
    expect(FloorPlanStore(dir.path).state().labels['desk-3']!.text, 'Operations');
    final down = plan.label('desk-3', '', null, 'Bo').done!;
    expect(down.label, isNull);
    expect(down.old?.text, 'Operations');
    expect(FloorPlanStore(dir.path).state().labels, isEmpty);
    // Taking down a sign that isn't there does nothing.
    final none = plan.label('desk-3', ' ', null, 'Bo');
    expect(none.error, isNull);
    expect(none.done!.label, isNull);
    expect(none.done!.old, isNull);
  });

  test('only desks get signs: not bean bags, kiosks or the meeting table', () {
    final plan = FloorPlanStore(dir.path);
    for (final id in ['beanbag-1', 'station-queue', 'meeting-1', 'nope']) {
      expect(plan.label(id, 'Ops', null, 'Ada').error, isNotNull, reason: id);
    }
    // The back office's desks can have one before they're built, ready for when they are.
    expect(plan.label(wingDesks.first.id, 'Ops', null, 'Ada').error, isNull);
  });

  test('the back office goes back a row at a time, as far as it can, and walls up only when nobody is there', () {
    final plan = FloorPlanStore(dir.path);
    expect(plan.wing, 0);
    expect(plan.shrink((_) => false).error, isNotNull, reason: 'nothing to wall up yet');
    for (var row = 1; row <= Wing.rows; row++) {
      expect(plan.expand().desks, [
        for (final d in wingDesks)
          if (d.wing == row) d.id,
      ]);
    }
    expect(plan.expand().error, "The back office can't go back any further");
    expect(FloorPlanStore(dir.path).wing, Wing.rows, reason: 'it stays built across a restart');
    final last = [
      for (final d in wingDesks)
        if (d.wing == Wing.rows) d,
    ];
    expect(plan.shrink((id) => id == last[1].id).error, contains(last[1].label));
    expect(plan.wing, Wing.rows);
    expect(plan.shrink((_) => false).desks, [for (final d in last) d.id]);
    expect(plan.wing, Wing.rows - 1);
  });

  test('a broken or tampered plan file comes back as what is valid of it', () {
    final file = File(p.join(dir.path, 'floorplan.json'));
    file.writeAsStringSync(
      jsonEncode({
        'wing': 99,
        'labels': {
          'desk-1': {'text': 'Ops', 'color': 'red'},
          'beanbag-2': {'text': 'x'},
          'desk-2': {'text': '   '},
        },
      }),
    );
    final plan = FloorPlanStore(dir.path).state();
    expect(plan.wing, Wing.rows);
    expect(plan.labels.keys, ['desk-1']);
    expect(plan.labels['desk-1']!.color, signColors[0].color);
    file.writeAsStringSync('{nope');
    expect(FloorPlanStore(dir.path).state().toJson(), cleanPlan(null).toJson());
    expect(file.readAsStringSync(), isNotEmpty);
  });
}
