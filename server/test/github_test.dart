// Port of tests/github.test.ts.
import 'package:agent_office_server/src/github.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

GhPull pull(int number, String state) => GhPull(
  number: number,
  title: 'PR $number',
  state: state,
  isDraft: false,
  url: '',
  author: '',
  labels: const [],
  reviewDecision: '',
  headRefName: 'b$number',
  baseRefName: 'main',
  createdAt: '',
  updatedAt: '',
  additions: 0,
  deletions: 0,
  checks: GhChecks.none,
  body: '',
  closes: const [],
);

List<int> numbers(List<GhPull> ps) => [for (final p in ps) p.number];

void main() {
  test('a pull request that was open at the last look and is merged now rings once', () {
    final w = MergeWatch();
    expect(
      numbers(w.look([pull(1, 'OPEN'), pull(2, 'MERGED'), pull(3, 'OPEN')])),
      <int>[],
      reason: 'nothing rings on the first look',
    );
    expect(numbers(w.look([pull(1, 'MERGED'), pull(2, 'MERGED'), pull(3, 'CLOSED')])), [1]);
    expect(numbers(w.look([pull(1, 'MERGED'), pull(2, 'MERGED')])), <int>[]);
  });

  test('a merge from the PR window rings right away, and not again when GitHub catches up', () {
    final w = MergeWatch();
    w.look([pull(5, 'OPEN'), pull(6, 'OPEN')]);
    expect(w.ring(5), isTrue);
    expect(w.ring(5), isFalse);
    // A look that started before the merge still says open; the next one says merged.
    expect(numbers(w.look([pull(5, 'OPEN'), pull(6, 'OPEN')])), <int>[]);
    expect(numbers(w.look([pull(5, 'MERGED'), pull(6, 'MERGED')])), [6]);
  });
}
