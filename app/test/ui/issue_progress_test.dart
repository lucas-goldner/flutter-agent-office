// Whether someone has started on an issue, and what the cork board on the wall pins (tests/issue-progress.test.ts).

import 'package:agent_office/ui/gh_logic.dart';
import 'package:agent_office/world/board_faces.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

GhIssue issue({
  int number = 7,
  List<Map<String, String>> labels = const [],
  List<String> assignees = const [],
  bool? taken,
  String state = 'OPEN',
}) => GhIssue.fromJson({
  'number': number,
  'title': 'Fix the door',
  'state': state,
  'url': '',
  'author': 'ada',
  'labels': labels,
  'assignees': assignees,
  'createdAt': '',
  'updatedAt': '',
  'body': '',
  'comments': 0,
  'taken': ?taken,
});

QueueTask task(String status) => QueueTask.fromJson({
  'id': 't1',
  'title': '#7 Fix the door',
  'prompt': '',
  'issue': 7,
  'status': status,
  'by': 'a',
  'at': 0,
});

void main() {
  test('an issue nobody has taken is not in progress', () {
    expect(inProgress(issue(), null), isFalse);
    expect(
      inProgress(
        issue(
          labels: [
            {'name': 'bug', 'color': '#d73a4a'},
          ],
        ),
        null,
      ),
      isFalse,
    );
  });

  test('an assigned issue is in progress', () {
    expect(inProgress(issue(assignees: ['ada']), null), isTrue);
  });

  test('an issue a worker just took is in progress before GitHub lists its assignee', () {
    expect(inProgress(issue(taken: true), null), isTrue);
  });

  test('an in-progress label puts an issue in progress, however it is spelled', () {
    for (final name in ['in progress', 'In-Progress', 'doing', 'WIP', 'started']) {
      expect(
        inProgress(
          issue(
            labels: [
              {'name': name, 'color': '#fff'},
            ],
          ),
          null,
        ),
        isTrue,
        reason: name,
      );
    }
  });

  test('only a running queue task puts its issue in progress', () {
    expect(inProgress(issue(), task('running')), isTrue);
    expect(inProgress(issue(), task('queued')), isFalse);
    expect(inProgress(issue(), task('done')), isFalse);
  });

  test('the cork board pins only the open issues nobody has started on', () {
    final items = [
      issue(number: 1),
      issue(number: 2, assignees: ['ada']),
      issue(number: 3, taken: true),
      issue(number: 4, state: 'CLOSED'),
      issue(number: 7),
      issue(number: 8),
    ];
    final st = GhState<GhIssue>(items: items, fetchedAt: 1, loading: false);
    expect(CorkBoardPainter.issueNumbers(st, {8}), [1, 7]);
    expect(CorkBoardPainter.issueNumbers(st, {8}, (n) => n == 7 ? task('running') : null), [1]);
  });
}
