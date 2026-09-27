import 'package:office_shared/protocol.dart';
import 'package:agent_office/ui/gh_logic.dart';
import 'package:flutter_test/flutter_test.dart';

GhPull pull(int n, {String state = 'OPEN', bool draft = false, String review = '', String updated = '2026-09-01'}) => GhPull.fromJson({
      'number': n,
      'title': 'PR $n',
      'state': state,
      'isDraft': draft,
      'url': 'https://github.com/acme/rocket/pull/$n',
      'author': 'ana',
      'labels': [],
      'reviewDecision': review,
      'headRefName': 'feat-$n',
      'baseRefName': 'main',
      'createdAt': '2026-08-01',
      'updatedAt': updated,
      'additions': 1,
      'deletions': 1,
      'checks': 'pass',
      'body': '',
      'closes': [],
    });

GhPullDetail detail({String state = 'OPEN', bool draft = false, String mergeable = 'MERGEABLE', String mss = 'CLEAN', String review = '', List<String> checks = const []}) =>
    GhPullDetail.fromJson({
      'number': 1,
      'body': '',
      'state': state,
      'isDraft': draft,
      'reviewDecision': review,
      'headRefName': 'feat',
      'baseRefName': 'main',
      'mergeable': mergeable,
      'mergeStateStatus': mss,
      'commits': 1,
      'comments': [],
      'reviews': [],
      'reviewComments': [],
      'checks': [for (final c in checks) {'name': c, 'state': c}],
      'repo': {'nameWithOwner': 'acme/rocket', 'methods': ['squash', 'merge']},
      'viewer': 'bot',
    });

void main() {
  test('pull columns', () {
    final cols = pullColumns([
      pull(1, draft: true),
      pull(2),
      pull(3, review: 'APPROVED'),
      pull(4, state: 'MERGED', updated: '2026-09-02'),
      pull(5, state: 'MERGED', updated: '2026-09-03'),
      pull(6, state: 'CLOSED'),
    ]);
    expect(cols.map((c) => c.title), ['✏️ Draft', '👀 In review', '👍 Approved', '🎉 Merged', '🗑️ Closed']);
    expect(cols.map((c) => c.items.map((p) => p.number).toList()), [
      [1],
      [2],
      [3],
      [5, 4],
      [6],
    ]);
  });

  test('issue columns: assigned, labelled or running is in progress', () {
    GhIssue issue(int n, {List<String> assignees = const [], List<String> labels = const [], String state = 'OPEN'}) => GhIssue.fromJson({
          'number': n,
          'title': 't',
          'state': state,
          'url': '',
          'author': 'a',
          'labels': [for (final l in labels) {'name': l, 'color': '#fff'}],
          'assignees': assignees,
          'createdAt': '',
          'updatedAt': '',
          'body': '',
          'comments': 0,
        });
    final running = QueueTask.fromJson({'id': 't', 'title': '', 'prompt': '', 'addedBy': '', 'addedAt': 0, 'status': 'running', 'issue': 4});
    final cols = issueColumns([issue(1), issue(2, assignees: ['bo']), issue(3, labels: ['WIP']), issue(4), issue(5, state: 'CLOSED')], (n) => n == 4 ? running : null);
    expect(cols.map((c) => c.items.map((i) => i.number).toList()), [
      [1],
      [2, 3, 4],
      [5],
    ]);
  });

  test('mergeStatus', () {
    expect(mergeStatus(detail(state: 'MERGED')).text, 'Merged.');
    expect(mergeStatus(detail(draft: true)).can, isFalse);
    final c = mergeStatus(detail(mergeable: 'CONFLICTING'));
    expect((c.text, c.can), ('This branch has conflicts with main that must be resolved first.', false));
    expect(mergeStatus(detail(mss: 'BLOCKED', checks: ['fail', 'fail'])).text, 'Merging is blocked: 2 checks are failing.');
    expect(mergeStatus(detail(mss: 'BLOCKED', review: 'REVIEW_REQUIRED')).text, 'Merging is blocked: it needs an approving review.');
    expect(mergeStatus(detail(checks: ['fail'])).text, '1 check failing. It can still be merged.');
    expect(mergeStatus(detail(checks: ['pending'])).auto, isTrue);
    expect(mergeStatus(detail(checks: ['pass'])).text, 'Ready to merge: no conflicts with main and all checks passed.');
    expect(mergeStatus(detail()).text, 'Ready to merge: no conflicts with main.');
  });

  test('prompts', () {
    final p = pull(7);
    expect(mergeCommand(p, GhMergeMethod.squash, true), 'gh pr merge 7 --squash --delete-branch --repo acme/rocket');
    expect(fixAndMergePrompt(p, GhMergeMethod.rebase, false), contains('`gh api repos/acme/rocket/pulls/7/comments`'));
    expect(fixConflictsPrompt(p, GhMergeMethod.merge, false), startsWith('Pull request #7 "PR 7" (https://github.com/acme/rocket/pull/7) has merge conflicts with `main`.'));
  });

  test('mergePrefFrom falls back to what the repo allows', () {
    expect(mergePrefFrom({'method': 'rebase', 'deleteBranch': false}, [GhMergeMethod.squash]), (method: GhMergeMethod.squash, deleteBranch: false));
    expect(mergePrefFrom(null, [GhMergeMethod.merge, GhMergeMethod.squash]), (method: GhMergeMethod.merge, deleteBranch: true));
  });

  test('labels', () {
    expect(labelIsDark('#0e8a16'), isTrue);
    expect(labelIsDark('#fbca04'), isFalse);
    expect(parseHex('#ff0000').toARGB32(), 0xFFFF0000);
  });
}
