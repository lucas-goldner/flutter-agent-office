// The messages and helpers upstream added to src/shared/protocol.ts (and status.ts / theme.ts):
// every new or changed message round-trips, server → client and client → server.
import 'dart:convert';

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

import 'protocol_test.dart' show machine, meeting, promptsState;

Map<String, dynamic> _json(Map<String, dynamic> m) => jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

/// A server frame parses into [T] and writes back out the same.
T server<T extends ServerMsg>(Map<String, dynamic> frame) {
  final json = _json(frame);
  final msg = ServerMsg.parse(json);
  expect(msg, isA<T>(), reason: '${frame['t']}');
  expect(_json(msg.toJson()), json, reason: '${frame['t']}');
  return msg as T;
}

/// A client message writes [frame] exactly, and [frame] parses back into the same message.
T client<T extends ClientMsg>(T msg, Map<String, dynamic> frame) {
  expect(_json(msg.toJson()), _json(frame), reason: '${frame['t']}');
  final back = ClientMsg.parse(_json(frame));
  expect(back, isA<T>(), reason: '${frame['t']}');
  expect(_json(back.toJson()), _json(frame), reason: '${frame['t']}');
  return back as T;
}

void main() {
  test('new server messages round-trip into their classes', () {
    server<ProjectsDirMsg>({
      't': 'projectsDir',
      'state': {'dir': '~/p', 'custom': false},
    });
    final act = server<PeerActMsg>({'t': 'peer.act', 'id': 'p1', 'golf': true, 'drink': 'beer'});
    expect(act.drink, DrinkId.beer);
    // Finishing a drink is `drink: null`, which is not the same as not saying.
    final done = server<PeerActMsg>({'t': 'peer.act', 'id': 'p1', 'drink': null});
    expect(done.drinkSet && done.drink == null, isTrue);
    expect(server<PeerActMsg>({'t': 'peer.act', 'id': 'p1'}).drinkSet, isFalse);
    server<GolfMsg>({'t': 'golf', 'id': 'p1', 'yaw': 0.5, 'loft': 0.3, 'power': 0.9});
    expect(server<PeerEmoteMsg>({'t': 'peer.emote', 'id': 'p1', 'emote': 'facepalm'}).emote, Emote.facepalm);
    server<TermTypingMsg>({'t': 'term.typing', 'workerId': 'w1', 'id': 'p2'});
    server<HornMsg>({'t': 'horn', 'by': 'Lucas'});
    final labeled = server<GhLabeledMsg>({
      't': 'gh.labeled',
      'kind': 'pull',
      'number': 12,
      'labels': [
        {'name': 'bug', 'color': '#d73a4a', 'description': "Something isn't working"},
      ],
    });
    expect(labeled.labels!.single.description, "Something isn't working");
    server<GhLabeledMsg>({'t': 'gh.labeled', 'kind': 'issue', 'number': 3, 'error': 'No such label'});
    server<BallMsg>({
      't': 'ball',
      'ball': {
        'shot': {'x': -12.0, 'y': 1.4, 'z': 10.0, 'vx': -5.0, 'vy': 6.0, 'vz': 0.0, 'by': 'p1', 'elapsed': 400},
      },
    });
    server<BallMsg>({'t': 'ball', 'ball': <String, dynamic>{}});
    server<CabinetMsg>({
      't': 'cabinet',
      'state': {'player': null, 'scores': []},
    });
    server<CabinetFrameMsg>({
      't': 'cabinet.frame',
      'frame': {
        'cells': '0' * 200,
        'next': 1,
        'hold': 7,
        'score': 0,
        'lines': 0,
        'level': 1,
        'pieces': 0,
        'state': 'over',
      },
    });
    final m = server<MeetingMsg>({
      't': 'meeting',
      'state': {'current': meeting, 'past': []},
    });
    expect(m.state.current!.pattern, MeetingPattern.review);
    expect(m.state.current!.seats.last.workerId, isNull);
    server<MeetingMsg>({
      't': 'meeting',
      'state': {'current': null, 'past': []},
    });
    server<MachineMsg>({'t': 'machine', 'state': machine});
    server<MachineMsg>({
      't': 'machine',
      'state': {'cpu': 0, 'cores': 2, 'memUsed': 1, 'memTotal': 2, 'history': [], 'workers': 0},
    });
    server<ThemeMsg>({
      't': 'theme',
      'state': {'pick': 'christmas', 'active': 'christmas', 'by': 'lucas', 'at': 9},
    });
    server<ThemeMsg>({
      't': 'theme',
      'state': {'pick': 'off', 'active': null},
    });
    server<PromptsMsg>({'t': 'prompts', 'state': promptsState});
    server<PromptsMsg>({
      't': 'prompts',
      'state': {'custom': <String, dynamic>{}},
    });
    server<LeaveOnMergeMsg>({
      't': 'leaveOnMerge',
      'state': {'on': false},
    });
  });

  test('changed data: GhPull, QueueTask, FloorInfo and WorkerInfo carry the new fields', () {
    final pulls = server<GhPullsMsg>({
      't': 'gh.pulls',
      'state': {
        'items': [
          {
            'number': 12,
            'title': 't',
            'state': 'OPEN',
            'isDraft': false,
            'url': 'u',
            'author': 'a',
            'labels': [],
            'reviewDecision': '',
            'headRefName': 'office/ada',
            'headRefOid': 'abc123',
            'baseRefName': 'main',
            'createdAt': '',
            'updatedAt': '',
            'additions': 1,
            'deletions': 2,
            'checks': 'pass',
            'body': '',
            'closes': [3],
          },
        ],
        'fetchedAt': 1,
        'loading': false,
      },
    });
    expect(pulls.state.items.single.headRefOid, 'abc123');
    final q = server<QueueMsg>({
      't': 'queue',
      'state': {
        'tasks': [
          {
            'id': 't1',
            'provider': 'claude',
            'model': 'sonnet',
            'effort': 'low',
            'title': 'x',
            'prompt': 'x',
            'addedBy': 'a',
            'addedAt': 1,
            'status': 'queued',
          },
        ],
        'maxWorkers': 2,
      },
    });
    expect(q.state.tasks.single.effort, AgentEffort.low);
  });

  test('new and changed client messages have the TS wire shape and parse back', () {
    client(const ActCmd(golf: true), {'t': 'act', 'golf': true});
    client(const ActCmd(drink: DrinkId.water), {'t': 'act', 'drink': 'water'});
    client(const ActCmd(drinkSet: true), {'t': 'act', 'drink': null});
    client(const ActCmd(smoke: true), {'t': 'act', 'smoke': true});
    client(const GolfCmd(yaw: 0.1, loft: 0.4, power: 1), {'t': 'golf', 'yaw': 0.1, 'loft': 0.4, 'power': 1});
    client(const CarryCmd(issue: 3, title: 'Bug'), {'t': 'carry', 'issue': 3, 'title': 'Bug'});
    client(const CarryCmd(), {'t': 'carry'});
    client(const EmoteCmd(Emote.dance), {'t': 'emote', 'emote': 'dance'});
    client(
      const WorkerSpawnCmd(
        deskId: 'desk-1',
        provider: AgentProvider.claude,
        model: 'opus',
        effort: AgentEffort.xhigh,
        issue: 7,
      ),
      {'t': 'worker.spawn', 'deskId': 'desk-1', 'provider': 'claude', 'model': 'opus', 'effort': 'xhigh', 'issue': 7},
    );
    client(const WorkerPromptCmd('w1', 'go', issue: 7), {
      't': 'worker.prompt',
      'workerId': 'w1',
      'prompt': 'go',
      'issue': 7,
    });
    client(const WorkerPromptCmd('w1', 'go'), {'t': 'worker.prompt', 'workerId': 'w1', 'prompt': 'go'});
    client(const StationPromptCmd(deskId: 'station-queue', prompt: 'Queue #3'), {
      't': 'station.prompt',
      'deskId': 'station-queue',
      'prompt': 'Queue #3',
    });
    client(const TermTypingCmd('w1'), {'t': 'term.typing', 'workerId': 'w1'});
    client(const DoingCmd(what: 'reading PR #12', reading: true), {
      't': 'doing',
      'what': 'reading PR #12',
      'reading': true,
    });
    client(const DoingCmd(), {'t': 'doing'});
    client(const HornCmd(), {'t': 'horn'});
    client(const GhLabelsCmd(kind: GhKind.pull, number: 12, add: ['bug'], remove: ['wontfix']), {
      't': 'gh.labels',
      'kind': 'pull',
      'number': 12,
      'add': ['bug'],
      'remove': ['wontfix'],
    });
    client(const QueueAddCmd(prompt: 'p', effort: AgentEffort.medium), {
      't': 'queue.add',
      'prompt': 'p',
      'effort': 'medium',
    });
    final start = client(
      const MeetingStartCmd(
        MeetingRequest(
          pattern: MeetingPattern.mapreduce,
          prompt: 'Audit each module',
          title: 'Audit',
          output: 'docs/audit.md',
          roles: ['Reducer', 'Mapper'],
          parts: ['src/a', 'src/b'],
          issue: 4,
          rounds: 2,
          budget: 2000000,
          provider: AgentProvider.claude,
          model: 'sonnet',
          effort: AgentEffort.low,
        ),
      ),
      {
        't': 'meeting.start',
        'pattern': 'mapreduce',
        'prompt': 'Audit each module',
        'title': 'Audit',
        'output': 'docs/audit.md',
        'roles': ['Reducer', 'Mapper'],
        'parts': ['src/a', 'src/b'],
        'issue': 4,
        'rounds': 2,
        'budget': 2000000,
        'provider': 'claude',
        'model': 'sonnet',
        'effort': 'low',
      },
    );
    expect(start.request.parts, ['src/a', 'src/b']);
    client(
      const MeetingStartCmd(
        MeetingRequest(
          pattern: MeetingPattern.review,
          prompt: 'Review #12',
          roles: ['Correctness', 'Security'],
          pr: 12,
        ),
      ),
      {
        't': 'meeting.start',
        'pattern': 'review',
        'prompt': 'Review #12',
        'roles': ['Correctness', 'Security'],
        'pr': 12,
      },
    );
    client(const MeetingStopCmd(), {'t': 'meeting.stop'});
    client(const MeetingClearCmd(), {'t': 'meeting.clear'});
    client(const MachineLimitCmd(8), {'t': 'machine.limit', 'limit': 8});
    client(const MachineLimitCmd(null), {'t': 'machine.limit', 'limit': null});
    client(const CabinetPlayCmd(game: 'abcd1234'), {'t': 'cabinet.play', 'game': 'abcd1234'});
    client(const CabinetPlayCmd(), {'t': 'cabinet.play'});
    client(const CabinetLeaveCmd(), {'t': 'cabinet.leave'});
    client(
      CabinetFrameCmd(
        CabinetFrame(
          cells: '0' * 200,
          next: 2,
          hold: 0,
          score: 100,
          lines: 1,
          level: 1,
          pieces: 5,
          state: PlayState.play,
        ),
      ),
      {
        't': 'cabinet.frame',
        'frame': {
          'cells': '0' * 200,
          'next': 2,
          'hold': 0,
          'score': 100,
          'lines': 1,
          'level': 1,
          'pieces': 5,
          'state': 'play',
        },
      },
    );
    client(const FloorGoCmd('f2'), {'t': 'floor.go', 'floor': 'f2'});
    client(const FloorGoCmd(roof, at: (x: 1.5, y: 0, z: -2, rotY: 3.1)), {
      't': 'floor.go',
      'floor': '@roof',
      'at': {'x': 1.5, 'y': 0, 'z': -2, 'rotY': 3.1},
    });
    client(const FloorRemoveCmd('f2'), {'t': 'floor.remove', 'floor': 'f2'});
    client(const ThemeSetCmd(ThemePick.halloween), {'t': 'theme.set', 'pick': 'halloween'});
    client(const LeaveOnMergeSetCmd(true), {'t': 'leaveOnMerge.set', 'on': true});
    client(const FloorProjectsDirCmd(''), {'t': 'floor.projectsDir', 'dir': ''});
    client(const PromptsSetCmd('issue.work', 'Do #{{number}}'), {
      't': 'prompts.set',
      'id': 'issue.work',
      'text': 'Do #{{number}}',
    });
    client(const PromptsSetCmd('issue.work', null), {'t': 'prompts.set', 'id': 'issue.work', 'text': null});
    client(const PromptsAgentCmd(AgentChoice(provider: AgentProvider.opencode, model: 'anthropic/claude')), {
      't': 'prompts.agent',
      'choice': {'provider': 'opencode', 'model': 'anthropic/claude'},
    });
    client(const PromptsAgentCmd(null), {'t': 'prompts.agent', 'choice': null});
    client(const BallTakeCmd(), {'t': 'ball.take'});
    client(const BallThrowCmd(x: -12, y: 1.4, z: 10, vx: -5, vy: 6, vz: 0), {
      't': 'ball.throw',
      'x': -12,
      'y': 1.4,
      'z': 10,
      'vx': -5,
      'vy': 6,
      'vz': 0,
    });
  });

  test('every older client message parses back the way it was written', () {
    final msgs = <ClientMsg>[
      const MoveCmd(x: 1, y: 0, z: 2, rotY: 0.5, moving: true),
      const SitCmd(seat: 'couch:1'),
      const ProfileCmd(name: 'Lucas', color: '#2a9d8f', look: Look(skin: 1, hair: 2, style: 0)),
      const WorkerResumeCmd('w1'),
      const WorkerKillCmd('w1', cleanup: WorktreeCleanup.worktree),
      const WorkerWorktreeCmd('w1'),
      const WorkerAttachCmd('w1'),
      const WorkerDetachCmd('w1'),
      const WorkerPrCmd('w1'),
      const TermInputCmd('w1', 'ls\r'),
      const TermResizeCmd('w1', cols: 100, rows: 30),
      const GhRefreshCmd(),
      const GhMergeCmd(number: 5, method: GhMergeMethod.rebase, deleteBranch: true, auto: true),
      const GhCommentCmd(kind: GhKind.issue, number: 3, body: 'hi'),
      const GongCmd(),
      const GhCloseCmd(
        kind: GhKind.pull,
        number: 4,
        comment: 'bye',
        reason: GhCloseReason.notPlanned,
        deleteBranch: true,
      ),
      const QueueRemoveCmd('t1'),
      const QueueMoveCmd('t1', -1),
      const QueueRetryCmd('t1'),
      const QueueClearCmd(),
      const QueueLimitCmd(3),
      const NotifyWebhookCmd('https://hooks.slack.com/x'),
      const NotifyTestCmd(),
      const VoiceCmd(voice: true, muted: false, sharing: true),
      const RtcCmd('p2', {'sdp': 'v=0'}),
      const ChatCmd('yo'),
      const TeamGetCmd(),
      const TeamInviteCmd('octocat'),
      const TeamRemoveCmd('octocat'),
      const AccountsGetCmd(),
      const AccountsInviteCmd(name: 'ann', role: AccountRole.admin),
      const AccountsCancelCmd('i1'),
      const AccountsRevokeCmd('a1'),
      const AccountsRoleCmd('a1', AccountRole.member),
      const AccountsSharedCmd(false),
      const ChangesWatchCmd('w1'),
      const ChangesUnwatchCmd('w1'),
      const ChangesDiffCmd('w1', 'a.ts'),
      const ChangesCommitCmd('w1', 'msg'),
      const ChangesDiscardCmd('w1', path: 'a.ts'),
      const ChangesPrCmd('w1', title: 't', body: 'b'),
      const UpgradeCheckCmd(),
      const UpgradeStartCmd(),
      const LimitsRefreshCmd(),
      const DecorRemoveCmd('d1'),
      const DecorUpdateCmd('d1', DecorPatch(wall: Side.west, u: 1, y: 2)),
      const JukeboxPlayCmd(track: 'coffee-break'),
      const JukeboxSkipCmd(),
      const JukeboxStopCmd(),
      const WbOpenCmd(),
      const WbCloseCmd(),
      const WbPointerCmd(
        WbPointer(x: 1, y: 2, tool: WbTool.laser, button: WbButton.down),
        selected: ['e1'],
      ),
      const FloorReposCmd(refresh: true),
      const FloorAddCmd('o/r'),
      const DogPetCmd(),
      const DogNameCmd('Rex'),
      const PingCmd(12.5),
    ];
    for (final m in msgs) {
      final json = _json(m.toJson());
      final back = ClientMsg.parse(json);
      expect(back.runtimeType, m.runtimeType, reason: m.t);
      expect(_json(back.toJson()), json, reason: m.t);
    }
    final u = ClientMsg.parse({'t': 'something.new', 'x': 1});
    expect(u, isA<UnknownCmd>());
    expect(u.toJson(), {'t': 'something.new', 'x': 1});
  });

  test('agent choices: Claude models and efforts', () {
    expect(claudeModels, ['fable', 'opus', 'sonnet', 'haiku']);
    expect(isClaudeModel('opus') && !isClaudeModel('gpt-5') && !isClaudeModel(null), isTrue);
    expect([for (final e in agentEfforts) e.wire], ['low', 'medium', 'high', 'xhigh', 'max']);
    expect(isAgentEffort('xhigh') && !isAgentEffort('extreme'), isTrue);
  });

  test('tokens and costs are written the way the office shows them', () {
    const u = Usage(input: 100, output: 50, reasoning: 5, cacheWrite: 10, cacheRead: 1000, cost: 0, calls: 1);
    expect(tokensOf(u), 1165);
    expect(
      tokensOf(const Usage(input: 1, output: 1, cacheWrite: 1, cacheRead: 1, cost: 0, calls: 1, totalTokens: 99)),
      99,
    );
    expect([950, 1234, 12345, 1234567, 12345678].map(fmtTokens), ['950', '1.2k', '12k', '1.23M', '12.3M']);
    expect([0.0, 0.001, 2.4, 1234.5].map(fmtCost), ['\$0.00', '<\$0.01', '\$2.40', '\$1,234.50']);
  });

  test('only pictures have a preview type, picked by extension', () {
    expect(changedImageType('assets/showcase/hero.webp'), 'image/webp');
    expect(changedImageType('a/b/PHOTO.JPG'), 'image/jpeg');
    expect(changedImageType('x.jpeg'), 'image/jpeg');
    expect(changedImageType('icon.svg'), 'image/svg+xml');
    expect(changedImageType('favicon.ico'), 'image/x-icon');
    for (final p in ['README.md', 'archive.zip', 'png', '.png', 'dir.png/file', 'x.constructor', 'x.__proto__', 'x.']) {
      expect(changedImageType(p), isNull, reason: p);
    }
  });

  test('holidays by the calendar, on the office clock', () {
    int at(int y, int m, int d, [int h = 0]) => DateTime.utc(y, m, d, h).millisecondsSinceEpoch;
    expect(calendarTheme(at(2026, 10, 1), 0), HolidayTheme.halloween);
    // 23:00 UTC on September 30th is already October an hour east.
    expect(calendarTheme(at(2026, 9, 30, 23), 60), HolidayTheme.halloween);
    expect(calendarTheme(at(2026, 9, 30, 23), 0), isNull);
    expect(calendarTheme(at(2026, 12, 24), 0), HolidayTheme.christmas);
    expect(calendarTheme(at(2027, 1, 1), 0), isNull);
    expect(activeTheme(ThemePick.auto, at(2026, 10, 1), 0), HolidayTheme.halloween);
    expect(activeTheme(ThemePick.off, at(2026, 10, 1), 0), isNull);
    expect(activeTheme(ThemePick.christmas, at(2026, 7, 1), 0), HolidayTheme.christmas);
    expect(themePicks, [ThemePick.auto, ThemePick.halloween, ThemePick.christmas, ThemePick.off]);
    expect(isThemePick('auto') && !isThemePick('easter'), isTrue);
  });

  WorkerInfo w({PrRef? pr, WorkerWorktree? worktree}) => WorkerInfo(
    id: 'w1',
    kind: WorkerKind.agent,
    deskId: 'desk-1',
    name: 'Ada',
    color: '#fff',
    status: WorkerStatus.done,
    acked: true,
    createdBy: 'l',
    createdAt: 0,
    cols: 80,
    rows: 24,
    viewers: const [],
    pr: pr,
    worktree: worktree,
  );
  GhPull pull(int number, String state, [String head = 'x']) => GhPull(
    number: number,
    title: '',
    state: state,
    isDraft: false,
    url: '',
    author: '',
    labels: const [],
    reviewDecision: '',
    headRefName: head,
    baseRefName: 'main',
    createdAt: '',
    updatedAt: '',
    additions: 0,
    deletions: 0,
    checks: GhChecks.none,
    body: '',
    closes: const [],
  );
  QueueTask task(int number, String state) => QueueTask(
    id: 't',
    title: '',
    prompt: '',
    addedBy: '',
    addedAt: 0,
    status: TaskStatus.done,
    workerId: 'w1',
    pr: QueueTaskPr(number: number, url: '', state: state, title: ''),
  );

  test("a worker's pull request: open wins, then merged, from its desk, its branch or its task", () {
    const wt = WorkerWorktree(path: 'p', branch: 'office/ada', base: 'b');
    expect(workerPr(w(), const [], const []), isNull);
    // Opened from its desk and not on the board yet: open.
    expect(workerPr(w(pr: const PrRef(number: 4, url: '')), const [], const []), (
      state: WorkerPrState.open,
      number: 4,
    ));
    expect(workerPr(w(pr: const PrRef(number: 4, url: '')), [pull(4, 'MERGED')], const []), (
      state: WorkerPrState.merged,
      number: 4,
    ));
    // By its branch, and a follow-up still open on it wins.
    expect(workerPr(w(worktree: wt), [pull(5, 'MERGED', 'office/ada'), pull(6, 'DRAFT', 'office/ada')], const []), (
      state: WorkerPrState.open,
      number: 6,
    ));
    // Its task's PR, even once it has dropped off the board.
    expect(workerPr(w(), const [], [task(7, 'MERGED')]), (state: WorkerPrState.merged, number: 7));
    expect(workerPr(w(), [pull(8, 'CLOSED')], [task(8, 'CLOSED')]), isNull);
  });
}
