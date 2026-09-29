import 'package:agent_office/ui/gh_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

GhIssue issue(int n, {List<String> labels = const [], String state = 'OPEN', String updated = '2026-09-01'}) =>
    GhIssue.fromJson({
      'number': n,
      'title': 'Issue $n',
      'state': state,
      'url': 'https://github.com/acme/rocket/issues/$n',
      'author': 'a',
      'labels': [
        for (final l in labels) {'name': l, 'color': '#${l.length}${l.length}0000'},
      ],
      'assignees': <String>[],
      'createdAt': '',
      'updatedAt': updated,
      'body': '',
      'comments': 0,
    });

GhLabel label(String name, [String? description]) => GhLabel(name: name, color: '#ffffff', description: description);

void main() {
  test('columns have keys, and the closed one a max instead of a cut', () {
    final items = [
      for (var i = 0; i < 45; i++)
        issue(i, state: 'CLOSED', updated: '2026-09-${(i % 28 + 1).toString().padLeft(2, '0')}'),
    ];
    final cols = issueColumns(items, (_) => null);
    expect(cols.map((c) => c.key), ['open', 'progress', 'closed']);
    expect(cols[2].items, hasLength(45));
    expect(cols[2].max, 40);
    expect(filterColumn(cols[2], const []).shown, hasLength(40));
    expect(filterColumn(cols[2], const []).count, '40');
    expect(pullColumns(const []).map((c) => c.key), ['draft', 'review', 'approved', 'merged', 'closed']);
  });

  test('a label filter shows cards with any of its labels, counting shown / total', () {
    final col = BoardColumn('open', '📥 Open', [
      issue(1, labels: ['bug']),
      issue(2, labels: ['ui', 'P1']),
      issue(3),
      issue(4, labels: ['P1']),
    ]);
    final f = filterColumn(col, ['bug', 'P1']);
    expect(f.shown.map((i) => i.number), [1, 2, 4]);
    expect(f.count, '3 / 4');
    expect(filterColumn(col, ['nope']).count, '0 / 4');
    expect(filterColumn(col, const []).count, '4');
  });

  test('the picker offers every label on the board A to Z, and ones picked earlier', () {
    final items = [
      issue(1, labels: ['bug', 'P1']),
      issue(2, labels: ['Docs', 'bug']),
    ];
    final all = boardLabels(items);
    expect(all.keys, ['bug', 'P1', 'Docs']);
    final col = BoardColumn('open', '📥 Open', [items[0]]);
    expect(pickerLabels(col, all, ['gone']), [
      (name: 'bug', count: 1),
      (name: 'Docs', count: 0),
      (name: 'gone', count: 0),
      (name: 'P1', count: 1),
    ]);
  });

  test('saved filters: per floor and board, garbled ones ignored', () {
    expect(labelFiltersKey('f2', '/x', 'issues'), 'agent-office.board-labels.f2.issues');
    expect(labelFiltersKey(null, '/x', 'pulls'), 'agent-office.board-labels./x.pulls');
    expect(parseLabelFilters('{"open":["bug",3],"closed":[],"x":"y"}'), {
      'open': ['bug'],
    });
    expect(parseLabelFilters('nope{'), isEmpty);
    expect(parseLabelFilters(null), isEmpty);
  });

  test('the label picker: changes, summary, rows and filter', () {
    final c = labelChanges({'a', 'b'}, {'b', 'c'});
    expect(c.add, ['c']);
    expect(c.remove, ['a']);
    expect(labelSummary({'a', 'b'}, {'b', 'c'}), '+c  −a');
    expect(labelSummary({'a'}, {'a'}), '1 label on it');
    expect(labelSummary({}, {}), '0 labels on it');
    final rows = labelRows(
      [label('zeta'), label('Bug')],
      [label('bug2'), label('zeta', 'last'), label('alpha'), label('Bug')],
    );
    expect(rows.map((l) => l.name), ['Bug', 'zeta', 'alpha', 'bug2']);
    expect(rows[1].description, 'last');
    expect(labelRows([label('x')], null).map((l) => l.name), ['x']);
    expect(labelMatches(label('good first issue', 'Easy one'), 'EASY'), isTrue);
    expect(labelMatches(label('bug'), 'ui'), isFalse);
    expect(labelMatches(label('bug'), '  '), isTrue);
  });
}
