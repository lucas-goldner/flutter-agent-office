// Port of tests/meetings.test.ts.
import 'dart:async';
import 'dart:io';

import 'package:agent_office_server/src/meetings.dart';
import 'package:agent_office_server/src/worktrees.dart';
import 'package:office_shared/shared.dart' hide MeetingRoom;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A worker at the table, as the fake manager keeps it: the test moves its status along.
class TableWorker {
  TableWorker(
    this.id,
    this.deskId,
    this.provider,
    this.model,
    this.effort,
    this.prompt,
    this.name,
    this.worktree,
    this.meeting,
  );
  final String id, deskId, name, meeting;
  final AgentProvider provider;
  final String? model;
  final AgentEffort? effort;
  final String prompt;
  final WorkerWorktree? worktree;
  WorkerStatus status = WorkerStatus.starting;
  Usage? usage;

  WorkerInfo get info => WorkerInfo(
    id: id,
    deskId: deskId,
    kind: WorkerKind.agent,
    provider: provider,
    model: model,
    effort: effort,
    prompt: prompt,
    name: name,
    color: '#fff',
    status: status,
    acked: true,
    createdBy: 'test',
    createdAt: 0,
    cols: 80,
    rows: 24,
    viewers: const [],
    worktree: worktree,
    meeting: meeting,
    usage: usage,
  );
}

class FakeMeetingWorkers implements MeetingWorkers {
  FakeMeetingWorkers(this.officeDefault);
  late MeetingRoom room;
  final workers = <TableWorker>[];
  final prompts = <({String id, String text})>[];
  final typed = <({String id, String data})>[];
  var _ids = 0;

  @override
  AgentProvider get defaultProvider => AgentProvider.claude;
  @override
  final AgentChoice? officeDefault;
  @override
  List<WorkerInfo> list() => [for (final w in workers) w.info];

  @override
  ({WorkerInfo? worker, String? error}) seat(
    String deskId,
    String by,
    String prompt,
    AgentProvider provider,
    String? model,
    AgentEffort? effort,
    ({String id, WorkerWorktree? worktree}) meeting,
  ) {
    if (workers.any((w) => w.deskId == deskId)) return (worker: null, error: 'taken');
    final w = TableWorker(
      'w${++_ids}',
      deskId,
      provider,
      model,
      effort,
      prompt,
      'Worker ${workers.length + 1}',
      meeting.worktree,
      meeting.id,
    );
    workers.add(w);
    prompts.add((id: w.id, text: prompt));
    return (worker: w.info, error: null);
  }

  @override
  String? prompt(String id, String text, [String? by]) {
    prompts.add((id: id, text: text));
    return null;
  }

  @override
  void write(String id, String data, String by) => typed.add((id: id, data: data));

  @override
  Future<({String? note, String? error})> kill(String id) async {
    workers.removeWhere((w) => w.id == id);
    room.onWorkerGone(id);
    return (note: null, error: null);
  }
}

class MeetingFixture {
  MeetingFixture({bool git = false, Map<PromptId, String> rewritten = const {}, AgentChoice? officeDefault})
    : dir = Directory.systemTemp.createTempSync('office-meeting-').path,
      manager = FakeMeetingWorkers(officeDefault) {
    Directory(p.join(dir, '.agent-office')).createSync(recursive: true);
    if (git) {
      void run(List<String> args) {
        final r = Process.runSync('git', args, workingDirectory: dir);
        if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
      }

      run(['init', '-q', '-b', 'main']);
      File(p.join(dir, 'README.md')).writeAsStringSync('# demo\n');
      File(p.join(dir, '.git', 'info', 'exclude')).writeAsStringSync('.agent-office/\n');
      run(['add', '.']);
      run(['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init']);
      run(['config', 'user.email', 't@t']);
      run(['config', 'user.name', 't']);
    }
    room = MeetingRoom(
      dir,
      p.join(dir, '.agent-office'),
      manager,
      git ? GitMeetingTrees(Worktrees(dir)) : null,
      MeetingEvents(
        update: (_) {},
        toast: (text, _) => toasts.add(text),
        hiringPaused: () => null,
        postReview: (pr, file) async {
          reviews.add((pr: pr, file: file));
          return 'https://github.com/o/r/pull/$pr#pullrequestreview-1';
        },
        prompt: (id) => rewritten[id] ?? prompts[id]!.text,
      ),
    );
    manager.room = room;
  }

  final String dir;
  final FakeMeetingWorkers manager;
  late final MeetingRoom room;
  final toasts = <String>[];
  final reviews = <({int pr, String file})>[];

  List<TableWorker> get workers => manager.workers;
  List<({String id, String text})> get said => manager.prompts;
  Meeting get current => room.state().current!;

  String cwd() {
    final wt = room.state().current?.worktree;
    return wt != null ? p.join(dir, wt.path) : dir;
  }

  /// The worker at seat [i] takes its part: it starts, writes its file (unless [skip]), and ends its turn.
  void take(int i, [String text = 'Some notes.', bool skip = false]) {
    final m = current;
    final t = m.turns.where((x) => x.seat == i).firstOrNull;
    expect(t, isNotNull, reason: 'seat $i has a part in round ${m.round}');
    final w = workers.firstWhere((x) => x.id == m.seats[i].workerId);
    w.status = WorkerStatus.working;
    room.onWorker(w.info);
    if (!skip) {
      final file = File(p.join(cwd(), t!.file));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }
    w.status = WorkerStatus.done;
    room.onWorker(w.info);
  }

  /// Workers who had no part yet say they're ready and end the turn.
  void settle() {
    for (final w in workers) {
      if (w.status != WorkerStatus.starting) continue;
      w.status = WorkerStatus.done;
      room.onWorker(w.info);
    }
  }

  String? start({
    MeetingPattern pattern = MeetingPattern.debate,
    String prompt = 'Which cache should we use?',
    List<String> roles = const [],
    int? rounds,
    String? output,
    String? title,
    int? budget,
    int? pr,
    List<String>? parts,
    AgentProvider? provider,
    String? model,
  }) => room.start(
    MeetingRequest(
      pattern: pattern,
      prompt: prompt,
      roles: roles,
      rounds: rounds,
      output: output,
      title: title,
      budget: budget,
      pr: pr,
      parts: parts,
      provider: provider,
      model: model,
    ),
    'Ada',
  );

  void close() {
    room.shutdown();
    Directory(dir).deleteSync(recursive: true);
  }
}

MeetingFixture fixture({bool git = false, Map<PromptId, String> rewritten = const {}, AgentChoice? officeDefault}) {
  final f = MeetingFixture(git: git, rewritten: rewritten, officeDefault: officeDefault);
  addTearDown(f.close);
  return f;
}

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('a debate runs its rounds and ends when the chair writes the decision', () {
    final f = fixture();
    expect(f.start(rounds: 3, output: 'docs/decision.md'), isNull);
    var m = f.current;
    expect(m.seats.length, 3);
    expect([for (final s in m.seats) s.role], ['Chair', 'Pragmatist', 'Skeptic']);
    expect(f.workers.length, 3);
    expect(f.said[0].text, contains('Round 1 of 3, proposing'));
    expect(f.said[0].text, contains('Which cache should we use?'));
    for (final i in [0, 1, 2]) {
      f.take(i);
    }
    m = f.current;
    expect(m.round, 2);
    expect(m.turns.length, 3);
    expect(m.turns.every((x) => x.state == MeetingTurnState.sent), isTrue);
    expect(f.said.last.text, contains('Round 2 of 3, critiquing'));
    for (final i in [0, 1, 2]) {
      f.take(i);
    }
    m = f.current;
    expect(m.round, 3);
    expect([for (final x in m.turns) (x.seat, x.file)], [(0, 'docs/decision.md')]);
    expect(f.said.last.text, contains('writing the decision'));
    f.take(0, '# We use Redis');
    m = f.current;
    expect(m.status, MeetingStatus.done);
    expect(File(p.join(f.dir, 'docs/decision.md')).readAsStringSync(), '# We use Redis');
    expect(m.preview, '# We use Redis');
    // The notes are kept by the floor's other state.
    expect(Directory(p.join(f.dir, '.agent-office', 'meetings', m.id)).existsSync(), isTrue);
  });

  test('the meeting stops once it runs over its token budget, and says so', () {
    final f = fixture();
    expect(f.start(budget: 100000), isNull);
    final w = f.workers[0];
    w.status = WorkerStatus.working;
    w.usage = const Usage(input: 90000, output: 20000, cacheRead: 0, cacheWrite: 0, cost: 0.5, calls: 3);
    f.room.onWorker(w.info);
    final m = f.current;
    expect(m.status, MeetingStatus.stopped);
    expect(m.reason, contains('over budget: 110k of 100k tokens'));
    // Whoever was busy is told to stop.
    expect(f.manager.typed, [(id: w.id, data: '\x1b')]);
  });

  test('a worker that ends its part without writing the file is reminded once, then the meeting stops', () {
    final f = fixture();
    expect(f.start(rounds: 2, output: 'decision.md'), isNull);
    for (final i in [0, 1, 2]) {
      f.take(i);
    }
    f.take(0, '', true);
    expect(f.said.last.text, matches(RegExp(r'without writing \S*/decision\.md,')));
    expect(f.current.status, MeetingStatus.running);
    f.take(0, '', true);
    final m = f.current;
    expect(m.status, MeetingStatus.stopped);
    expect(m.reason, contains('round limit without writing decision.md'));
  });

  test('sending a worker home stops the meeting and names who left', () async {
    final f = fixture();
    expect(f.start(), isNull);
    await f.manager.kill(f.current.seats[2].workerId!);
    final m = f.current;
    expect(m.status, MeetingStatus.stopped);
    expect(m.reason, contains('the Skeptic (Worker 3) was sent home'));
  });

  test('red / blue ends early when red finds nothing more', () {
    final f = fixture();
    expect(f.start(pattern: MeetingPattern.redblue, prompt: 'The login change', rounds: 3), isNull);
    f.settle();
    var m = f.current;
    expect([for (final s in m.seats) s.role], ['Blue team', 'Red team']);
    f.take(1, '- src/login.ts:12 — token compared with ==');
    m = f.current;
    expect(m.step, 2);
    expect(f.said.last.text, contains('Round 1 of 3, fixing.'));
    f.take(0, 'Fixed it with a constant-time compare.');
    m = f.current;
    expect(m.round, 2);
    f.take(1, 'NO FINDINGS');
    m = f.current;
    expect(m.lastRound, 2);
    expect(m.turns[0].file, m.output);
    f.take(0, '# Red / blue\n\nOne finding, fixed.');
    expect(f.current.status, MeetingStatus.done);
  });

  test('a review panel posts the combined review on the pull request', () async {
    final f = fixture();
    expect(f.start(pattern: MeetingPattern.review, prompt: 'Review it'), contains('needs a pull request'));
    expect(f.start(pattern: MeetingPattern.review, prompt: 'Review it', pr: 42), isNull);
    var m = f.current;
    expect(m.output, 'reviews/pr-42.md');
    expect(m.title, 'Review of PR #42');
    expect(f.said[1].text, contains('through your lens, Security'));
    for (final i in [0, 1, 2]) {
      f.take(i, '- a.ts:1 — something');
    }
    expect(f.said.last.text, contains('**[Security]**'));
    f.take(0, 'Looks fine. **[Security]** a.ts:1 — something');
    await until(() => f.current.review != null);
    m = f.current;
    expect(m.status, MeetingStatus.done);
    expect(f.reviews, [(pr: 42, file: p.join(f.dir, 'reviews/pr-42.md'))]);
    expect(m.review?.url, 'https://github.com/o/r/pull/42#pullrequestreview-1');
  });

  test('map-reduce hands each mapper its own parts', () {
    final f = fixture();
    expect(f.start(pattern: MeetingPattern.mapreduce, parts: ['src/a.ts']), contains('at least 2 parts'));
    expect(f.start(pattern: MeetingPattern.mapreduce, parts: ['src/a.ts', 'src/b.ts', 'src/c.ts']), isNull);
    final mapper1 = f.said.firstWhere((x) => x.id == f.workers[1].id).text;
    final mapper2 = f.said.firstWhere((x) => x.id == f.workers[2].id).text;
    expect(mapper1, contains('- src/a.ts\n- src/c.ts'));
    expect(mapper2, contains('- src/b.ts\n'));
    expect(f.said[0].text, contains('Round 1 has no part for you'));
  });

  test('bad requests are turned away before anyone sits down', () {
    final f = fixture();
    expect(f.start(prompt: '  '), contains('what the meeting is about'));
    expect(f.start(output: '../x.md'), contains('..'));
    expect(f.start(output: '/etc/x'), contains('relative'));
    expect(f.start(output: '.agent-office/x.md'), contains('.agent-office'));
    expect(f.start(roles: ['a', 'b', 'c', 'd', 'e', 'f']), contains('2 to 5 workers'));
    expect(f.start(pattern: MeetingPattern.redblue, roles: ['a', 'b', 'c']), contains('seats 2 workers'));
    expect(f.workers, isEmpty);
    expect(f.start(), isNull);
    expect(f.start(), contains('busy'));
  });

  test(
    'in a git project the output is committed on the meeting branch, which outlives the room being cleared',
    () async {
      final f = fixture(git: true);
      expect(f.start(rounds: 2, output: 'docs/decision.md', title: 'Pick a cache'), isNull);
      final m0 = f.current;
      expect(m0.worktree!.branch, startsWith('office/meeting-pick-a-cache-'));
      expect(f.workers.every((w) => w.worktree?.path == m0.worktree!.path), isTrue);
      // Every file a part names is a full path inside the meeting's worktree, never the project folder around it.
      expect(f.said[0].text, contains('Write it to ${p.join(f.cwd(), '.meeting', 'r1-1-chair.md')},'));
      for (final i in [0, 1, 2]) {
        f.take(i);
      }
      f.take(0, '# Redis\n');
      await until(() => f.current.commit != null);
      final m = f.current;
      expect(m.status, MeetingStatus.done);
      expect(m.commit, isNotNull);
      String git(List<String> args) => '${Process.runSync('git', args, workingDirectory: f.dir).stdout}'.trim();
      expect(git(['show', '${m.worktree!.branch}:docs/decision.md']), '# Redis');
      // Notes stay out of the commit.
      expect(git(['show', '--name-only', '--format=', m.worktree!.branch]), 'docs/decision.md');
      expect(f.room.clear('Ada'), isNull);
      await until(() => !Directory(p.join(f.dir, m.worktree!.path)).existsSync());
      expect(f.workers, isEmpty);
      expect(Directory(p.join(f.dir, m.worktree!.path)).existsSync(), isFalse);
      expect(git(['rev-parse', '--abbrev-ref', m.worktree!.branch]), m.worktree!.branch);
      expect(f.room.state().current, isNull);
      expect(
        f.room.state().past[0].summary,
        matches(
          RegExp(r'Debate · 2 rounds · 0 tokens · \$0\.00 · ✅ docs/decision\.md on office/meeting-pick-a-cache-'),
        ),
      );
    },
  );

  test('a meeting says what the office’s rewritten prompts say, and seats the default worker when nobody picked one', () {
    final f = fixture(
      rewritten: {
        'meeting.brief': 'You are the {{role}}. Topic: {{about}}{{nothing}}',
        'meeting.debate.propose': 'Pitch it as the {{role}}, into {{file}}.',
        'meeting.nudge': 'Still waiting on {{file}}!',
      },
      officeDefault: const AgentChoice(provider: AgentProvider.claude, model: 'sonnet', effort: AgentEffort.medium),
    );
    expect(f.start(rounds: 3), isNull);
    expect(
      f.said[0].text,
      'You are the Chair. Topic: Which cache should we use?{{nothing}}\n\nRound 1 of 3, proposing. Pitch it as the Chair, into ${p.join(f.cwd(), '.agent-office', 'meetings', f.current.id, 'r1-1-chair.md')}.',
    );
    expect([
      for (final w in f.workers) [w.provider, w.model, w.effort],
    ], List.filled(3, [AgentProvider.claude, 'sonnet', AgentEffort.medium]));
    // A worker that ends its turn without its part is nudged in the office's words.
    final w = f.workers[0];
    w.status = WorkerStatus.working;
    f.room.onWorker(w.info);
    w.status = WorkerStatus.done;
    f.room.onWorker(w.info);
    expect(f.said.last.text, matches(RegExp(r'^Still waiting on \S+r1-1-chair\.md!$')));
    // Picked, the meeting's own choice wins.
    final g = fixture(
      officeDefault: const AgentChoice(provider: AgentProvider.claude, model: 'sonnet'),
    );
    expect(g.start(provider: AgentProvider.claude, model: 'haiku'), isNull);
    expect([for (final x in g.workers) x.model], ['haiku', 'haiku', 'haiku']);
  });

  test('a meeting carries on after a restart of the office, where it was', () {
    final f = fixture();
    expect(f.start(rounds: 2), isNull);
    for (final i in [0, 1, 2]) {
      f.take(i);
    }
    f.room.shutdown();
    final again = MeetingRoom(
      f.dir,
      p.join(f.dir, '.agent-office'),
      f.manager,
      null,
      MeetingEvents(update: (_) {}, toast: (_, _) {}, hiringPaused: () => null, postReview: (_, _) async => ''),
    );
    addTearDown(again.shutdown);
    final m = again.state().current!;
    expect(m.round, 2);
    expect(m.status, MeetingStatus.running);
    expect(m.toJson(), f.current.toJson());
  });
}
