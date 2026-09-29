import 'dart:convert';

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

/// Parses a frame the way it comes off the socket, and checks it writes back out the same.
ServerMsg roundTrip(Map<String, dynamic> frame) {
  final json = jsonDecode(jsonEncode(frame)) as Map<String, dynamic>;
  final msg = ServerMsg.parse(json);
  expect(jsonDecode(jsonEncode(msg.toJson())), json);
  return msg;
}

final worker = <String, dynamic>{
  'id': 'w1',
  'kind': 'agent',
  'provider': 'claude',
  'deskId': 'desk-3',
  'name': 'Ada',
  'color': '#ff8a5b',
  'status': 'needs_input',
  'acked': false,
  'createdBy': 'lucas',
  'createdAt': 1700000000000,
  'prompt': 'Fix the login redirect',
  'worktree': {'path': '.office/worktrees/ada', 'branch': 'office/ada', 'base': 'abc123', 'from': 'main'},
  'pr': {'number': 12, 'url': 'https://github.com/o/r/pull/12'},
  'cols': 120,
  'rows': 40,
  'viewers': ['lucas'],
  'viewerIds': ['p1', 'p9'],
  'activity': 'Bash: npm test',
  'action': 'test',
  'effort': 'high',
  'waitingSince': 1700000002000,
  'meeting': 'm1',
  'task': {'name': 'Fix Login Redirect', 'summary': 'Running the tests'},
  'usage': {'input': 1200, 'output': 300, 'cacheWrite': 10, 'cacheRead': 5000, 'cost': 0.42, 'calls': 7},
  'lastInput': {'by': 'lucas', 'at': 1700000001000},
};

final peer = <String, dynamic>{
  'id': 'p1',
  'name': 'Lucas',
  'color': '#2a9d8f',
  'look': {'skin': 2, 'hair': 3, 'style': 1},
  'x': 8.0,
  'y': 0.0,
  'z': 7.5,
  'rotY': 1.25,
  'moving': false,
  'voice': true,
  'muted': false,
  'sharing': false,
  'seat': 'couch:1',
  'floor': 'f1',
  'golfing': true,
  'carrying': {'issue': 3, 'title': 'Bug'},
  'drink': 'maitai',
  'doing': "in Ada's terminal",
  'reading': false,
};

Map<String, dynamic> floorView() => {
  'floor': 'f1',
  'project': {
    'name': 'r',
    'dir': '/srv/r',
    'branch': 'main',
    'agentCmd': 'claude',
    'defaultProvider': 'claude',
    'agentProviders': ['claude', 'codex'],
  },
  'workers': [worker],
  'issues': {
    'items': [
      {
        'number': 3,
        'title': 'Bug',
        'state': 'OPEN',
        'url': 'u',
        'author': 'a',
        'labels': [
          {'name': 'bug', 'color': 'd73a4a'},
        ],
        'assignees': [],
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-02T00:00:00Z',
        'body': '',
        'comments': 2,
      },
    ],
    'fetchedAt': 1700000000000,
    'loading': false,
  },
  'pulls': {'items': [], 'error': 'gh not signed in', 'fetchedAt': 0, 'loading': true},
  'queue': {
    'tasks': [
      {
        'id': 't1',
        'title': 'Do it',
        'prompt': 'Do it',
        'addedBy': 'lucas',
        'addedAt': 1,
        'status': 'done',
        'outcome': 'done',
        'pr': {'number': 4, 'url': 'u', 'state': 'MERGED', 'title': 'x'},
      },
    ],
    'maxWorkers': 2,
  },
  'decor': [
    {
      'id': 'd1',
      'url': 'https://e.com/a.png',
      'wall': 'north',
      'u': 1.5,
      'y': 2.0,
      'w': 1.0,
      'h': 0.75,
      'frame': 2,
      'by': 'lucas',
      'at': 5,
    },
  ],
  'services': {'items': [], 'port': 4000},
  'dog': {
    'name': 'Biscuit',
    'coat': 1,
    'path': [
      [0.5, 1.0],
      [2.0, 3.5],
    ],
    'speed': 1.2,
    'elapsed': 250,
    'act': 'wag',
    'petBy': 'lucas',
  },
  'jukebox': {'on': true, 'track': 'coffee-break', 'by': 'lucas', 'startedAt': 1700000000000, 'elapsed': 1234},
  'whiteboard': {
    'elements': [
      {
        'id': 'e1',
        'type': 'freedraw',
        'version': 4,
        'versionNonce': 991,
        'isDeleted': false,
        'index': 'a0',
        'points': [
          [0, 0],
          [1, 2],
        ],
        'strokeColor': '#1e1e1e',
      },
    ],
    'people': ['p1'],
  },
  'cabinet': {
    'player': {'id': 'p1', 'name': 'Lucas', 'game': 'abcd1234ef'},
    'scores': [
      {
        'game': 'abcd1234ef',
        'name': 'Lucas',
        'color': '#2a9d8f',
        'score': 12400,
        'lines': 12,
        'level': 2,
        'at': 1700000000000,
      },
    ],
    'frame': {
      'cells': '0' * 200,
      'next': 3,
      'hold': 0,
      'score': 12400,
      'lines': 12,
      'level': 2,
      'pieces': 40,
      'state': 'paused',
    },
  },
  'meeting': {
    'current': meeting,
    'past': [meetingRecord],
  },
  'ball': {'holder': 'p1'},
};

final meeting = <String, dynamic>{
  'id': 'm1',
  'pattern': 'review',
  'title': 'Review #12',
  'prompt': 'Review pull request #12',
  'output': 'reviews/pr-12.md',
  'seats': [
    {'role': 'Correctness', 'deskId': 'meeting-1', 'workerId': 'w1', 'workerName': 'Ada', 'tokens': 1200, 'cost': 0.25},
    {'role': 'Security', 'deskId': 'meeting-2'},
  ],
  'parts': ['src/a.ts', 'src/b.ts'],
  'pr': 12,
  'issue': 3,
  'provider': 'claude',
  'model': 'opus',
  'effort': 'max',
  'rounds': 2,
  'round': 1,
  'step': 0,
  'lastRound': 1,
  'turns': [
    {
      'seat': 0,
      'doing': 'reviewing',
      'file': '.meeting/r1-correctness.md',
      'state': 'working',
      'sentAt': 5,
      'retried': true,
    },
    {'seat': 1, 'doing': 'reviewing', 'file': '.meeting/r1-security.md', 'state': 'waiting'},
  ],
  'budget': 2000000,
  'tokens': 1200,
  'cost': 0.25,
  'costKnown': true,
  'status': 'stopped',
  'reason': 'Ada went home',
  'calledBy': 'lucas',
  'startedAt': 1700000000000,
  'finishedAt': 1700000001000,
  'worktree': {'path': '.agent-office/worktrees/m1', 'branch': 'meeting/review-12', 'base': 'abc', 'from': 'main'},
  'notes': '.meeting',
  'commit': 'def',
  'review': {'url': 'https://github.com/o/r/pull/12#pullrequestreview-1'},
  'preview': '# Review',
  'cleared': true,
};

final meetingRecord = <String, dynamic>{
  'id': 'm0',
  'pattern': 'debate',
  'title': 'Pick a cache',
  'status': 'done',
  'summary': '🗣️ Debate · 3 rounds',
  'calledBy': 'lucas',
  'finishedAt': 1,
  'branch': 'meeting/pick-a-cache',
  'output': 'docs/decisions/pick-a-cache.md',
};

final machine = <String, dynamic>{
  'cpu': 37.5,
  'cores': 8,
  'memUsed': 8000000000,
  'memTotal': 16000000000,
  'history': [
    [10, 50],
    [12.5, 60],
  ],
  'pressure': 'memory is 93% used',
  'workers': 4,
  'limit': 6,
  'ceiling': 10,
  'set': {'limit': 6, 'by': 'lucas', 'at': 4},
};

final promptsState = <String, dynamic>{
  'custom': {
    'issue.work': {'text': 'Do #{{number}}', 'by': 'ann', 'at': 1},
  },
  'agent': {'provider': 'claude', 'model': 'opus', 'effort': 'high', 'by': 'ann', 'at': 2},
};

void main() {
  test('welcome round-trips with its flat FloorView', () {
    final msg = roundTrip({
      't': 'welcome',
      'you': 'p1',
      'peers': [peer],
      'floors': [
        {
          'id': 'f1',
          'name': 'r',
          'repo': 'o/r',
          'dir': '/srv/r',
          'palette': 0,
          'local': true,
          'addedBy': 'lucas',
          'addedAt': 1,
          'workers': 1,
          'busy': 1,
          'waiting': 1,
          'people': 1,
        },
      ],
      'projectsDir': {'dir': '~/agent-office/projects', 'custom': true, 'by': 'lucas', 'at': 2},
      'ice': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': ['turn:a', 'turn:b'],
          'username': 'u',
          'credential': 'c',
        },
      ],
      'chat': [
        {'from': 'p1', 'name': 'Lucas', 'color': '#000000', 'text': 'hi', 'at': 3, 'account': true},
      ],
      'invites': false,
      'version': 'abc',
      'upgrade': {'available': false, 'phase': 'idle'},
      'usage': {
        'total': {'input': 1, 'output': 2, 'cacheWrite': 3, 'cacheRead': 4, 'cost': 1.5, 'calls': 1},
        'today': {'input': 0, 'output': 0, 'cacheWrite': 0, 'cacheRead': 0, 'cost': 0, 'calls': 0},
        'day': '2026-09-27',
        'budget': 20,
        'pauseHiring': false,
      },
      'limits': {
        'plan': 'max',
        'windows': [
          {'label': '5h session', 'pct': 42, 'resetsAt': 1700000100000},
        ],
        'at': 1700000000000,
      },
      'me': {
        'account': {'name': 'lucas', 'role': 'admin'},
        'admin': true,
      },
      'notify': {
        'webhook': {'kind': 'slack', 'hint': 'hooks.slack.com/…', 'by': 'lucas', 'at': 1},
      },
      'machine': machine,
      'sky': {
        'lat': 35.68,
        'lon': 139.69,
        'utcOffset': 540,
        'weather': 'rain',
        'intensity': 0.4,
        'city': 'Tokyo',
        'temp': 21.5,
      },
      'theme': {'pick': 'auto', 'active': 'halloween'},
      'prompts': promptsState,
      'leaveOnMerge': {'on': true, 'by': 'lucas', 'at': 3},
      ...floorView(),
    });
    expect(msg, isA<WelcomeMsg>());
    final w = msg as WelcomeMsg;
    expect(w.peers.single.look, const Look(skin: 2, hair: 3, style: 1));
    expect(w.view.workers.single.status, WorkerStatus.needsInput);
    expect(w.view.workers.single.worktree!.from, 'main');
    expect(w.view.dog!.path.last, (2.0, 3.5));
    expect(w.view.whiteboard.elements.single.raw['points'], isNotNull);
    expect(w.ice.first.urls, ['stun:stun.l.google.com:19302']);
    expect(w.sky.weather, Weather.rain);
    expect(w.me.account!.role, AccountRole.admin);
    expect(w.view.queue.tasks.single.outcome, TaskOutcome.done);
    expect(w.projectsDir.custom, isTrue);
    expect(w.machine.history.last, (12.5, 60.0));
    expect(w.theme.active, HolidayTheme.halloween);
    expect(w.prompts.custom['issue.work']!.by, 'ann');
    expect(w.prompts.agent!.effort, AgentEffort.high);
    expect(w.leaveOnMerge.on, isTrue);
    expect(w.peers.single.drink, DrinkId.maitai);
    expect(w.peers.single.carrying!.issue, 3);
    expect(w.view.workers.single.action, WorkerAction.test);
    expect(w.view.workers.single.viewerIds, ['p1', 'p9']);
    expect(w.view.cabinet.frame!.state, PlayState.paused);
    expect(w.view.meeting.current!.turns.first.state, MeetingTurnState.working);
    expect(w.view.meeting.current!.review!.url, isNotNull);
    expect(w.view.ball.holder, 'p1');
  });

  test("an older server's welcome still reads: a plain projects folder, and nothing new", () {
    final w = ServerMsg.parse({'t': 'welcome', 'projectsDir': '/srv'}) as WelcomeMsg;
    expect(w.projectsDir.dir, '/srv');
    expect(w.projectsDir.custom, isFalse);
    expect(w.theme.pick, ThemePick.auto);
    expect(w.theme.active, isNull);
    expect(w.prompts.custom, isEmpty);
    expect(w.leaveOnMerge.on, isFalse);
    expect(w.view.cabinet.player, isNull);
    expect(w.view.meeting.current, isNull);
    expect(w.view.ball.toJson(), isEmpty);
  });

  test('floor.enter with no floor keeps its nulls', () {
    final msg =
        roundTrip({'t': 'floor.enter', 'peers': [], ...floorView(), 'floor': null, 'project': null, 'dog': null})
            as FloorEnterMsg;
    expect(msg.view.floor, isNull);
    expect(msg.view.dog, isNull);
  });

  test('small messages round-trip into their classes', () {
    expect(
      roundTrip({'t': 'peer.move', 'id': 'p1', 'x': 1.5, 'y': 0, 'z': -2.25, 'rotY': 3.1, 'moving': true}),
      isA<PeerMoveMsg>(),
    );
    expect(roundTrip({'t': 'peer.act', 'id': 'p1', 'smoke': true}), isA<PeerActMsg>());
    expect(roundTrip({'t': 'term.data', 'workerId': 'w1', 'data': '\x1b[31mhi'}), isA<TermDataMsg>());
    expect(roundTrip({'t': 'worker.update', 'worker': worker}), isA<WorkerUpdateMsg>());
    expect(
      roundTrip({'t': 'chat', 'from': 'p', 'name': 'n', 'color': '#111111', 'text': 'yo', 'at': 9}),
      isA<ChatMsg>(),
    );
    expect(roundTrip({'t': 'gong', 'why': 'merged', 'pr': 12}), isA<GongMsg>());
    expect(roundTrip({'t': 'toast', 'text': 'Nope', 'level': 'error'}), isA<ToastMsg>());
    expect(
      roundTrip({
        't': 'wb.pointer',
        'id': 'p1',
        'x': 10,
        'y': 20,
        'tool': 'laser',
        'button': 'down',
        'selected': ['e1'],
      }),
      isA<WbPointerMsg>(),
    );
    expect(roundTrip({'t': 'pong', 'at': 12.5, 'now': 1700000000000}), isA<PongMsg>());
    expect(
      roundTrip({
        't': 'rtc',
        'from': 'p2',
        'data': {'sdp': 'v=0', 'type': 'offer'},
      }),
      isA<RtcMsg>(),
    );
    expect(
      roundTrip({
        't': 'changes',
        'state': {
          'workerId': 'w1',
          'dir': '',
          'base': 'HEAD',
          'ahead': 0,
          'files': [
            {
              'path': 'a.ts',
              'status': '?',
              'additions': 3,
              'deletions': 0,
              'binary': false,
              'uncommitted': true,
              'sig': '12:34',
            },
          ],
          'more': 0,
          'at': 5,
        },
      }),
      isA<ChangesMsg>(),
    );
    expect(roundTrip({'t': 'accounts.invited', 'error': 'Admins only'}), isA<AccountsInvitedMsg>());
  });

  test('screen reads its runs and cursor', () {
    final msg =
        roundTrip({
              't': 'screen',
              'workerId': 'w1',
              'cols': 80,
              'rows': 24,
              'lines': {
                '0': [
                  ['hello ', -1, -1, 0],
                  ['world', rgbFlag | 0xff0000, 4, flagBold | flagInverse],
                ],
                '5': [],
              },
              'full': false,
              'cursor': [11, 0],
            })
            as ScreenMsg;
    expect(msg.lines[0]![1], const Run('world', rgbFlag | 0xff0000, 4, 3));
    expect(msg.lines[0]![1].bold && msg.lines[0]![1].inverse, isTrue);
    expect(msg.lines[5], isEmpty);
    expect(msg.cursor, (11, 0));
  });

  test('tolerant: unknown types, unknown enums and missing fields', () {
    final u = ServerMsg.parse({'t': 'something.new', 'x': 1});
    expect(u, isA<UnknownMsg>());
    expect(u.toJson(), {'t': 'something.new', 'x': 1});
    final w =
        (ServerMsg.parse({
                  't': 'worker.update',
                  'worker': {'id': 'w', 'status': 'dreaming', 'kind': 7},
                })
                as WorkerUpdateMsg)
            .worker;
    expect(w.status, WorkerStatus.idle);
    expect(w.kind, WorkerKind.agent);
    expect(w.viewers, isEmpty);
    expect(w.usage, isNull);
    final sky =
        (ServerMsg.parse({
                  't': 'sky',
                  'state': {'weather': 'hail'},
                })
                as SkyMsg)
            .state;
    expect(sky.weather, Weather.clear);
    expect(ServerMsg.parse({'t': 'queue'}), isA<QueueMsg>());
    expect(ServerMsg.parse({}), isA<UnknownMsg>());
  });

  test('client messages have the TS wire shape, without nulls', () {
    expect(const MoveCmd(x: 1, y: 0, z: 2.5, rotY: 0.5, moving: true).toJson(), {
      't': 'move',
      'x': 1,
      'y': 0,
      'z': 2.5,
      'rotY': 0.5,
      'moving': true,
    });
    expect(const ActCmd().toJson(), {'t': 'act'});
    expect(const ActCmd(smoke: false).toJson(), {'t': 'act', 'smoke': false});
    expect(const SitCmd().toJson(), {'t': 'sit'});
    expect(const WorkerSpawnCmd(deskId: 'desk-1', kind: WorkerKind.shell).toJson(), {
      't': 'worker.spawn',
      'deskId': 'desk-1',
      'kind': 'shell',
    });
    expect(
      const WorkerSpawnCmd(
        deskId: 'desk-2',
        prompt: 'hi',
        worktree: true,
        provider: AgentProvider.opencode,
        model: 'm',
      ).toJson(),
      {'t': 'worker.spawn', 'deskId': 'desk-2', 'prompt': 'hi', 'worktree': true, 'provider': 'opencode', 'model': 'm'},
    );
    expect(const WorkerKillCmd('w1', cleanup: WorktreeCleanup.all).toJson(), {
      't': 'worker.kill',
      'workerId': 'w1',
      'cleanup': 'all',
    });
    expect(const TermResizeCmd('w1', cols: 100, rows: 30).toJson(), {
      't': 'term.resize',
      'workerId': 'w1',
      'cols': 100,
      'rows': 30,
    });
    expect(
      const GhCloseCmd(kind: GhKind.issue, number: 4, reason: GhCloseReason.notPlanned, deleteBranch: false).toJson(),
      {'t': 'gh.close', 'kind': 'issue', 'number': 4, 'reason': 'not planned', 'deleteBranch': false},
    );
    expect(const GhMergeCmd(number: 5, method: GhMergeMethod.squash, deleteBranch: true, auto: false).toJson(), {
      't': 'gh.merge',
      'number': 5,
      'method': 'squash',
      'deleteBranch': true,
      'auto': false,
    });
    expect(const AccountsInviteCmd(role: AccountRole.member).toJson(), {'t': 'accounts.invite', 'role': 'member'});
    expect(const ChangesDiscardCmd('w1').toJson(), {'t': 'changes.discard', 'workerId': 'w1'});
    expect(const DecorUpdateCmd('d1', DecorPatch(wall: Side.west, u: 1, y: 2)).toJson(), {
      't': 'decor.update',
      'id': 'd1',
      'decor': {'wall': 'west', 'u': 1, 'y': 2},
    });
    expect(const JukeboxPlayCmd().toJson(), {'t': 'jukebox.play'});
    expect(const WbPointerCmd(WbPointer(x: 1, y: 2, tool: WbTool.pointer, button: WbButton.up)).toJson(), {
      't': 'wb.pointer',
      'x': 1,
      'y': 2,
      'tool': 'pointer',
      'button': 'up',
    });
    expect(const FloorReposCmd(refresh: true).toJson(), {'t': 'floor.repos', 'refresh': true});
    expect(const PingCmd(12.5).toJson(), {'t': 'ping', 'at': 12.5});
    expect(const GongCmd().toJson(), {'t': 'gong'});
  });
}
