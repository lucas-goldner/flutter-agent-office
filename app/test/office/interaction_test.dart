// Whether a desk key does anything at what's in reach (tests/interaction.test.ts).

import 'package:agent_office/office/interaction.dart';
import 'package:agent_office/world/collider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

InteractionState state({WorkerInfo? worker, bool room = false, GhIssue? note, bool carrying = false}) =>
    (worker: worker, room: room, note: note, carrying: carrying);

Interactable interaction(InteractKind kind, {String? deskId}) =>
    Interactable(kind: kind, x: 0, z: 0, radius: 1, deskId: deskId);

WorkerInfo worker(String status) => WorkerInfo.fromJson({
  'id': 'worker-1',
  'kind': 'agent',
  'deskId': 'desk-1',
  'name': 'W',
  'color': '#fff',
  'status': status,
  'acked': true,
  'createdBy': 't',
  'createdAt': 0,
  'cols': 80,
  'rows': 24,
  'viewers': <String>[],
});

void main() {
  test('unused desk keys are not handled without an interaction target', () {
    for (final key in [DeskKey.e, DeskKey.p, DeskKey.r, DeskKey.x, DeskKey.b, DeskKey.c, DeskKey.o]) {
      expect(interactionAvailable(null, key, state()), isFalse, reason: '$key should remain available to movement');
    }
  });

  test('E remains handled by representative nearby interactions', () {
    expect(interactionAvailable(interaction(InteractKind.desk, deskId: 'desk-1'), DeskKey.e, state()), isTrue);
    expect(interactionAvailable(interaction(InteractKind.elevator), DeskKey.e, state()), isTrue);
    expect(interactionAvailable(interaction(InteractKind.dog), DeskKey.e, state()), isTrue);
    expect(interactionAvailable(interaction(InteractKind.ladder), DeskKey.e, state()), isTrue);
  });

  test('desk-specific keys are handled only when their action is available', () {
    final desk = interaction(InteractKind.desk, deskId: 'desk-1');
    expect(interactionAvailable(desk, DeskKey.b, state()), isTrue);
    expect(interactionAvailable(desk, DeskKey.c, state()), isFalse);
    final w = worker('working');
    expect(interactionAvailable(desk, DeskKey.b, state(worker: w)), isFalse);
    expect(interactionAvailable(desk, DeskKey.c, state(worker: w)), isTrue);
    expect(interactionAvailable(desk, DeskKey.x, state(worker: w)), isTrue);
    expect(interactionAvailable(desk, DeskKey.r, state(worker: w)), isFalse);
    expect(interactionAvailable(desk, DeskKey.r, state(worker: worker('exited'))), isTrue);
  });

  test('carried issue actions still consume E at their valid destinations', () {
    for (final target in [
      interaction(InteractKind.issues),
      interaction(InteractKind.queue),
      interaction(InteractKind.meeting),
      interaction(InteractKind.desk, deskId: 'desk-1'),
    ]) {
      expect(interactionAvailable(target, DeskKey.e, state(carrying: true)), isTrue);
    }
  });

  test('L hangs a sign over any desk, empty or not, but not over a bean bag or a meeting chair', () {
    final w = worker('working');
    expect(interactionAvailable(interaction(InteractKind.desk, deskId: 'desk-1'), DeskKey.l, state()), isTrue);
    expect(interactionAvailable(interaction(InteractKind.desk, deskId: 'desk-1'), DeskKey.l, state(worker: w)), isTrue);
    expect(interactionAvailable(interaction(InteractKind.desk, deskId: 'beanbag-1'), DeskKey.l, state()), isFalse);
    expect(
      interactionAvailable(interaction(InteractKind.desk, deskId: 'meeting-1'), DeskKey.l, state(room: true)),
      isFalse,
    );
    expect(interactionAvailable(null, DeskKey.l, state()), isFalse);
  });
}
