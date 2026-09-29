import 'package:agent_office/office/carry.dart';
import 'package:agent_office/world/board_faces.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

WorkerInfo worker(WorkerStatus status, {WorkerKind kind = WorkerKind.agent}) => WorkerInfo(
  id: 'w',
  kind: kind,
  deskId: 'desk-1',
  name: 'Pixel',
  color: '#fff',
  status: status,
  acked: false,
  createdBy: 't',
  createdAt: 0,
  cols: 80,
  rows: 24,
  viewers: const [],
);

void main() {
  test('who can take a card', () {
    expect(cantTakeCard(worker(WorkerStatus.idle)), '');
    expect(cantTakeCard(worker(WorkerStatus.working)), '');
    expect(cantTakeCard(worker(WorkerStatus.idle, kind: WorkerKind.shell)), 'Pixel is a shell, not an agent');
    expect(cantTakeCard(worker(WorkerStatus.offline)), contains('asleep'));
    expect(cantTakeCard(worker(WorkerStatus.needsInput)), contains('waiting on an answer'));
  });

  test("a card's prompt is the issue's", () {
    final p = cardPrompt(const CarriedIssue(issue: 42, title: 'Fix the login'));
    expect(p, contains('#42'));
    expect(p, contains('Fix the login'));
  });

  test('a note on the board is found where it is drawn, tilt and all', () {
    final layout = corkLayout([3, 5, 8]);
    expect(layout.spots, hasLength(3));
    for (final s in layout.spots) {
      expect(corkNoteAt(layout.spots, s.x / 1200, s.y / 600), s.number);
    }
    // Bare cork in a corner.
    expect(corkNoteAt(layout.spots, 0.005, 0.01), isNull);
    expect(corkLayout(const []).spots, isEmpty);
    // At most 15 notes go up.
    expect(corkLayout([for (var i = 0; i < 20; i++) i]).spots, hasLength(15));
  });
}
