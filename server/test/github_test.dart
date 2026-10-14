// Port of tests/github.test.ts.
import 'dart:async';

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

  group('claims (#268)', () {
    GhIssue issue(int number, [List<String> assignees = const []]) => GhIssue(
      number: number,
      title: 'Issue $number',
      state: 'OPEN',
      url: '',
      author: '',
      labels: const [],
      assignees: assignees,
      createdAt: '',
      updatedAt: '',
      body: '',
      comments: 0,
    );
    List<int> taken(List<GhIssue> issues) => [
      for (final i in issues)
        if (i.taken == true) i.number,
    ];

    test('an issue a worker took is marked at once, before GitHub has answered', () {
      final c = Claims()..take(7);
      expect(taken(c.mark([issue(6), issue(7)])), [7]);
      // A list that comes back while GitHub is still assigning it doesn't have its assignee yet.
      expect(taken(c.mark([issue(6), issue(7)], 1000)), [7]);
    });

    test('it stays marked over a list asked for before it was assigned, until one asked for after', () {
      final c = Claims();
      final answered = c.take(7);
      answered(true, 2000);
      expect(taken(c.mark([issue(7)], 1500)), [7], reason: 'asked before GitHub had it assigned');
      expect(c.has(7), isTrue);
      final fresh = c.mark([
        issue(7, ['octocat']),
      ], 2500);
      expect(taken(fresh), isEmpty, reason: 'GitHub lists its assignee now, which is what keeps it In progress');
      expect(fresh[0].assignees, ['octocat']);
      expect(c.has(7), isFalse);
    });

    test("an issue GitHub wouldn't assign goes back to where it was", () {
      final c = Claims();
      final answered = c.take(7);
      final shown = c.mark([issue(7)]);
      expect(taken(shown), [7]);
      answered(false);
      final back = c.mark(shown);
      expect(taken(back), isEmpty);
      expect(back[0].toJson().containsKey('taken'), isFalse);
    });

    test('handed over twice, the first answer failing leaves the second one standing', () {
      final c = Claims();
      final first = c.take(7);
      final second = c.take(7);
      first(false);
      expect(taken(c.mark([issue(7)])), [7]);
      second(true, 3000);
      expect(
        taken(
          c.mark([
            issue(7, ['octocat']),
          ], 3500),
        ),
        isEmpty,
      );
    });
  });

  group('older gh (#323)', () {
    test('gh JSON field errors keep the field that failed', () {
      expect(
        friendlyGhError('Unknown JSON field: "headRefOid"\nAvailable fields:\n  title\n  updatedAt\n  url'),
        'Unknown JSON field: "headRefOid"',
      );
    });

    test('pull request listing works when older gh versions reject optional fields', () async {
      const unsupported = {'url', 'headRefOid', 'updatedAt', 'statusCheckRollup', 'closingIssuesReferences'};
      final calls = <String>[];
      Future<String> runner(List<String> args, String cwd, [int timeout = 30000]) async {
        if (args[0] == 'repo') {
          return '{"nameWithOwner":"acme/app","squashMergeAllowed":true,"mergeCommitAllowed":false,"rebaseMergeAllowed":false}';
        }
        if (args[0] != 'pr' || args[1] != 'list') return '[]';
        final fields = args.last.split(',');
        calls.add(fields.join(','));
        final bad = fields.where(unsupported.contains).firstOrNull;
        if (bad != null) throw GhError(friendlyGhError('Unknown JSON field: "$bad"\nAvailable fields:\n  title'));
        if (args[args.indexOf('--state') + 1] != 'open') return '[]';
        return '[{"number":7,"title":"Fix login","state":"OPEN","isDraft":false,"author":{"login":"ada"},'
            '"labels":[{"name":"bug","color":"d73a4a"}],"reviewDecision":"","headRefName":"fix-login",'
            '"baseRefName":"main","createdAt":"2026-01-01T00:00:00Z","additions":4,"deletions":2,"body":"Closes #1"}]';
      }

      GhState<GhPull>? pulls;
      final github = GitHub('/repo', (_) {}, (state) => pulls = state, runner);
      await github.refresh();
      expect(pulls?.error, isNull);
      expect(pulls?.items.length, 1);
      expect(pulls?.items[0].url, 'https://github.com/acme/app/pull/7');
      expect(pulls?.items[0].updatedAt, '2026-01-01T00:00:00Z');
      expect(pulls?.items[0].checks, GhChecks.none);
      expect(calls.any((fields) => !fields.contains('url') && !fields.contains('updatedAt')), isTrue);
    });

    test('a claim shows on the board for everyone before gh answers, and goes back when it fails', () async {
      final states = <GhState<GhIssue>>[];
      final assigning = Completer<String>();
      Future<String> runner(List<String> args, String cwd, [int timeout = 30000]) {
        if (args.take(2).join(' ') == 'issue edit') return assigning.future;
        if (args.take(2).join(' ') == 'issue list') {
          return Future.value(
            args.contains('open')
                ? '[{"number":7,"title":"Seven","state":"OPEN","url":"u","author":{"login":"a"},"labels":[],'
                      '"assignees":[],"createdAt":"","updatedAt":"","body":"","comments":0}]'
                : '[]',
          );
        }
        return Future.value('[]');
      }

      final github = GitHub('/repo', states.add, (_) {}, runner);
      await github.refresh();
      expect(states.last.items.single.taken, isNull);
      final claimed = github.claim(7);
      expect(states.last.items.single.taken, isTrue, reason: 'taken at once');
      assigning.completeError(GhError('HTTP 403: no access'));
      expect(await claimed, contains('no access'));
      expect(states.last.items.single.taken, isNull, reason: 'back where it was');
    });
  });
}
