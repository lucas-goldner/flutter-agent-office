// The shared half of tests/meetings.test.ts, and the meeting room's patterns (meetings.dart). The
// meetings themselves (server/meetings.ts) are the server's.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

Meeting meeting({
  MeetingStatus status = MeetingStatus.done,
  String? reason,
  MeetingReview? review,
  String? commit,
  WorkerWorktree? worktree,
  bool costKnown = true,
}) => Meeting(
  id: 'm1',
  pattern: MeetingPattern.debate,
  title: 'Pick a cache',
  prompt: 'Redis or memcached?',
  output: 'docs/decisions/pick-a-cache.md',
  seats: const [
    MeetingSeat(role: 'Chair', deskId: 'meeting-1', workerId: 'w1', workerName: 'Ada', tokens: 1200, cost: 0.4),
  ],
  rounds: 3,
  round: 2,
  step: 0,
  turns: const [
    MeetingTurn(seat: 0, doing: 'proposing', file: '.meeting/r1-chair.md', state: MeetingTurnState.done, sentAt: 1),
  ],
  budget: 3000000,
  tokens: 1234567,
  cost: 2.4,
  costKnown: costKnown,
  status: status,
  reason: reason,
  calledBy: 'lucas',
  startedAt: 1700000000000,
  worktree: worktree,
  notes: '.meeting',
  commit: commit,
  review: review,
);

void main() {
  test('only the real meeting patterns pass, not what every object inherits', () {
    for (final id in meetingPatternIds) {
      expect(isMeetingPattern(id.wire), isTrue);
    }
    for (final v in ['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf', '', 'nope', 1, null]) {
      expect(isMeetingPattern(v), isFalse, reason: '$v');
    }
  });

  test('every pattern has its roles for its seats, and a default output', () {
    for (final id in meetingPatternIds) {
      final p = meetingPatterns[id]!;
      expect(p.roles.length, greaterThanOrEqualTo(p.seats.max), reason: id.wire);
      expect(p.seats.min <= p.seats.defaultValue && p.seats.defaultValue <= p.seats.max, isTrue);
      expect(p.rounds.min <= p.rounds.defaultValue && p.rounds.defaultValue <= p.rounds.max, isTrue);
      expect(outputProblem(p.output('pick-a-cache', 12)), isNull);
    }
    expect(meetingPatterns[MeetingPattern.review]!.output('x', 12), 'reviews/pr-12.md');
    expect(meetingPatterns[MeetingPattern.review]!.output('x', null), 'reviews/pr-n.md');
    expect(meetingPatterns[MeetingPattern.debate]!.output('x', null), 'docs/decisions/x.md');
  });

  test('titles become file and branch names', () {
    expect(slugify('Pick a cache!'), 'pick-a-cache');
    expect(slugify('Café au lait — naïve'), 'cafe-au-lait-nai-ve');
    expect(slugify(''), 'meeting');
    expect(slugify('---'), 'meeting');
    expect(slugify('${'x' * 60} y'), 'x' * 40);
    expect(slugify('ab cd', 3), 'ab');
  });

  test('an output path has to be a file inside the checkout', () {
    expect(outputProblem('docs/a.md'), isNull);
    for (final p in [
      '',
      '  ',
      '/etc/passwd',
      'C:/x.md',
      r'\x.md',
      'a/../b.md',
      './a.md',
      'a//b.md',
      '.git/x',
      '.agent-office/x',
      '.meeting/x',
      'a\u0001b',
      'x' * 201,
    ]) {
      expect(outputProblem(p), isNotNull, reason: p);
    }
  });

  test('the line on the door says how it went', () {
    expect(meetingSpend(tokens: 1234567, cost: 2.4, costKnown: true), '1.23M tokens · \$2.40');
    expect(meetingSpend(tokens: 950, cost: 0.5, costKnown: false), '950 tokens · \$0.50+');
    expect(meetingSpend(tokens: 12000, cost: 0, costKnown: false), '12k tokens');
    const wt = WorkerWorktree(path: '.agent-office/worktrees/m1', branch: 'meeting/pick-a-cache', base: 'abc');
    expect(
      meetingSummary(meeting(commit: 'abc123', worktree: wt)),
      '🗣️ Debate · 2 rounds · 1.23M tokens · \$2.40 · ✅ docs/decisions/pick-a-cache.md on meeting/pick-a-cache',
    );
    expect(
      meetingSummary(meeting(worktree: wt)),
      "🗣️ Debate · 2 rounds · 1.23M tokens · \$2.40 · ✅ docs/decisions/pick-a-cache.md in meeting/pick-a-cache's worktree",
    );
    expect(
      meetingSummary(meeting(review: const MeetingReview(url: 'u'))),
      '🗣️ Debate · 2 rounds · 1.23M tokens · \$2.40 · ✅ docs/decisions/pick-a-cache.md · posted on the PR',
    );
    expect(
      meetingSummary(meeting(review: const MeetingReview(error: 'no gh'))),
      "🗣️ Debate · 2 rounds · 1.23M tokens · \$2.40 · ✅ docs/decisions/pick-a-cache.md · couldn't post it: no gh",
    );
    expect(
      meetingSummary(meeting(status: MeetingStatus.stopped, reason: 'over budget')),
      '🗣️ Debate · in round 2 of 3 · 1.23M tokens · \$2.40 · ⛔ over budget',
    );
    expect(meetingSummary(meeting(status: MeetingStatus.running)), '🗣️ Debate · round 2 of 3 · 1.23M tokens · \$2.40');
    final r = meetingRecord(meeting(worktree: wt), 42);
    expect(r.finishedAt, 42);
    expect(r.branch, 'meeting/pick-a-cache');
    expect(r.summary, meetingSummary(meeting(worktree: wt)));
  });
}
