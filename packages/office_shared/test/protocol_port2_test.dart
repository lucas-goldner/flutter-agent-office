// The messages and fields upstream added to src/shared/protocol (between 44aecc1 and the split into
// src/shared/protocol/*): every one round-trips, server → client and client → server, as the TS
// office writes it.
import 'dart:convert';

import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

import 'protocol_test.dart' show worker;
import 'protocol_upstream_test.dart' show client, server;

Map<String, dynamic> _json(Map<String, dynamic> m) => jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

void main() {
  test('a worker carries its own branch, its other repositories, its lost worktree and its clock', () {
    final w = {
      ...worker,
      'provider': 'pi',
      'worktree': {'path': 'wt/a', 'branch': 'fix-x', 'base': 'abc', 'from': 'main', 'made': 'fix-x'},
      'lost': {'branch': 'origin'},
      'pr': {'number': 9, 'url': 'https://github.com/o/r/pull/9'},
      'pastPrs': [7, 8],
      'repos': [
        {
          'floor': 'api',
          'name': 'api',
          'repo': 'o/api',
          'dir': '/srv/api',
          'path': 'workspaces/w1/api',
          'branch': 'office/ada-w1',
          'base': 'def',
          'from': 'main',
          'pr': {'number': 3, 'url': 'https://github.com/o/api/pull/3'},
        },
      ],
      'usage': {
        'input': 1,
        'output': 2,
        'cacheWrite': 0,
        'cacheRead': 0,
        'cost': 0,
        'calls': 1,
        'contextSize': 128000,
        'model': 'claude-opus-5-5',
      },
      'workedMs': 60000,
      'workingSince': 1700000000000,
      'via': 'herald',
    };
    final msg = server<WorkerUpdateMsg>({'t': 'worker.update', 'worker': w});
    final info = msg.worker;
    expect(info.provider, AgentProvider.pi);
    expect(info.worktree!.made, 'fix-x');
    expect(info.lost, LostBranch.origin);
    expect(info.pastPrs, [7, 8]);
    expect(info.repos!.single.pr!.number, 3);
    expect(info.usage!.model, 'claude-opus-5-5');
    expect(info.via, 'herald');
    // An older office's worker has none of them.
    final old = WorkerInfo.fromJson(worker);
    expect(old.lost, isNull);
    expect(old.pastPrs, isEmpty);
    expect(old.repos, isNull);
    expect(old.toJson().containsKey('pastPrs'), isFalse);
  });

  test('sent home on a map that keeps them, a worker goes into its jail', () {
    final gone = server<WorkerRemoveMsg>({
      't': 'worker.remove',
      'workerId': 'w1',
      'jail': {
        'prisoners': [
          {'id': 'w1', 'name': 'Ada', 'color': '#ff8a5b', 'at': 5, 'workedMs': 100},
        ],
        'bones': 1,
      },
    });
    expect(gone.jail!.prisoners.single.name, 'Ada');
    expect(server<WorkerRemoveMsg>({'t': 'worker.remove', 'workerId': 'w2'}).jail, isNull);
    server<WorkerWorktreeMsg>({
      't': 'worker.worktree',
      'workerId': 'w1',
      'state': {
        'exists': true,
        'dirty': 3,
        'ahead': 1,
        'unpushed': 1,
        'repos': [
          {
            'name': 'web',
            'state': {'exists': true, 'dirty': 2, 'ahead': 1, 'unpushed': 1},
          },
          {
            'name': 'api',
            'state': {'exists': true, 'dirty': 1, 'ahead': 0, 'unpushed': 0},
          },
        ],
      },
    });
  });

  test('darts, axes and cars on the wire', () {
    final up = server<PeerActMsg>({'t': 'peer.act', 'id': 'p1', 'throwing': 'axe'});
    expect(up.throwing, BarGame.axe);
    final back = server<PeerActMsg>({'t': 'peer.act', 'id': 'p1', 'throwing': null});
    expect(back.throwingSet && back.throwing == null, isTrue);
    client(const ActCmd(throwing: BarGame.darts), {'t': 'act', 'throwing': 'darts'});
    client(const ActCmd(throwingSet: true), {'t': 'act', 'throwing': null});
    client(const TossCmd(game: BarGame.axe, u: 0.1, v: -0.2, stick: true, n: 3), {
      't': 'toss',
      'game': 'axe',
      'u': 0.1,
      'v': -0.2,
      'stick': true,
      'n': 3,
    });
    server<TossMsg>({'t': 'toss', 'id': 'p1', 'game': 'darts', 'u': 0.01, 'v': 0.1, 'stick': true, 'n': 1});
    client(const CarEnterCmd(2, CarSeat.passenger), {'t': 'car.enter', 'car': 2, 'seat': 'passenger'});
    client(const CarLeaveCmd(), {'t': 'car.leave'});
    client(const CarDriveCmd(car: 1, x: 2.5, z: 3, rotY: 0.5, speed: 12, steer: -0.2), {
      't': 'car.drive',
      'car': 1,
      'x': 2.5,
      'z': 3,
      'rotY': 0.5,
      'speed': 12,
      'steer': -0.2,
    });
    client(const CarHonkCmd(), {'t': 'car.honk'});
    final cars = server<CarsMsg>({
      't': 'cars',
      'cars': [
        {'x': 1, 'z': 2, 'rotY': 0, 'speed': 0, 'steer': 0, 'driver': 'p1'},
      ],
      'answer': true,
    });
    expect(cars.cars.single.driver, 'p1');
    server<CarMoveMsg>({'t': 'car.move', 'car': 0, 'x': 1, 'z': 2, 'rotY': 3, 'speed': 4, 'steer': 0.1});
    server<CarHonkMsg>({'t': 'car.honk', 'car': 4});
    final peer = PeerInfo.fromJson({'id': 'p', 'name': 'P', 'throwing': 'darts', 'lite': true});
    expect(peer.throwing, BarGame.darts);
    expect(peer.toJson()['lite'], isTrue);
  });

  test('sign-ins of your own', () {
    final state = server<SignInsMsg>({
      't': 'signins',
      'state': {
        'claude': {'status': 'ok', 'how': 'login', 'who': 'ada@example.com (Max)'},
        'github': {
          'status': 'busy',
          'how': 'login',
          'pending': {'url': 'https://github.com/login/device', 'code': 'ABCD-1234'},
        },
        'office': true,
      },
    }).state;
    expect(state.github.pending!.code, 'ABCD-1234');
    expect(state.claude.status, SignInStatus.ok);
    server<SignInsNeededMsg>({'t': 'signins.needed', 'which': 'github', 'why': 'Sign in to GitHub to merge'});
    client(const SignInsGetCmd(), {'t': 'signins.get'});
    client(const SignInsStartCmd(SignInKind.github), {'t': 'signins.start', 'which': 'github'});
    client(const SignInsCodeCmd('xyz'), {'t': 'signins.code', 'code': 'xyz'});
    client(const SignInsCancelCmd(SignInKind.claude), {'t': 'signins.cancel', 'which': 'claude'});
    client(const SignInsTokenCmd(SignInKind.github, 'ghp_x'), {
      't': 'signins.token',
      'which': 'github',
      'token': 'ghp_x',
    });
    client(const SignInsOfficeCmd(SignInKind.claude), {'t': 'signins.office', 'which': 'claude'});
    client(const SignInsSignoutCmd(SignInKind.github), {'t': 'signins.signout', 'which': 'github'});
  });

  test('workers across repositories, and rebuilding lost ones', () {
    final spawn = client(
      const WorkerSpawnCmd(
        deskId: 'desk-1',
        prompt: 'p',
        repos: ['api', 'web'],
        via: 'herald',
        provider: AgentProvider.cursor,
      ),
      {
        't': 'worker.spawn',
        'deskId': 'desk-1',
        'prompt': 'p',
        'provider': 'cursor',
        'repos': ['api', 'web'],
        'via': 'herald',
      },
    );
    expect(spawn.repos, ['api', 'web']);
    client(const WorkerRebuildCmd('w1', all: true), {'t': 'worker.rebuild', 'workerId': 'w1', 'all': true});
    client(const ChangesWatchCmd('w1', repo: 'api'), {'t': 'changes.watch', 'workerId': 'w1', 'repo': 'api'});
    client(const ChangesUnwatchCmd('w1'), {'t': 'changes.unwatch', 'workerId': 'w1'});
    client(const ChangesDiffCmd('w1', 'a.ts', repo: 'api'), {
      't': 'changes.diff',
      'workerId': 'w1',
      'path': 'a.ts',
      'repo': 'api',
    });
    client(const ChangesCommitCmd('w1', 'msg', repo: 'api'), {
      't': 'changes.commit',
      'workerId': 'w1',
      'message': 'msg',
      'repo': 'api',
    });
    client(const ChangesDiscardCmd('w1', repo: 'api'), {'t': 'changes.discard', 'workerId': 'w1', 'repo': 'api'});
    client(const ChangesPrCmd('w1', title: 't', body: 'b', repo: 'api'), {
      't': 'changes.pr',
      'workerId': 'w1',
      'title': 't',
      'body': 'b',
      'repo': 'api',
    });
    server<ChangesDiffMsg>({
      't': 'changes.diff',
      'workerId': 'w1',
      'repo': 'api',
      'path': 'a',
      'diff': '',
      'truncated': false,
    });
    server<ChangesMsg>({
      't': 'changes',
      'state': {
        'workerId': 'w1',
        'repo': 'api',
        'dir': 'x',
        'base': 'main',
        'ahead': 0,
        'files': [],
        'more': 0,
        'at': 1,
      },
    });
  });

  test('floors: clones on their way, cancelling one, signs and the back office', () {
    final floors = server<FloorsMsg>({
      't': 'floors',
      'floors': [
        {
          'id': 'f1',
          'name': 'api',
          'dir': '/srv/api',
          'branch': 'main',
          'palette': 0,
          'cloning': true,
          'clone': {'step': 'Receiving objects', 'percent': 64, 'detail': '1 MiB'},
          'addedBy': 'ada',
          'addedAt': 1,
          'workers': 0,
          'busy': 0,
          'waiting': 0,
          'people': 0,
          'wing': 1,
        },
      ],
    });
    expect(cloneLabel(floors.floors.single.clone), '⏳ Receiving objects 64%');
    expect(cloneStep(null), 'Cloning…');
    client(const FloorCancelCmd('f1'), {'t': 'floor.cancel', 'floor': 'f1'});
    client(const DeskLabelCmd('desk-1', 'Ops', color: '#ef476f'), {
      't': 'desk.label',
      'deskId': 'desk-1',
      'text': 'Ops',
      'color': '#ef476f',
    });
    client(const FloorExpandCmd(), {'t': 'floor.expand'});
    client(const FloorShrinkCmd(), {'t': 'floor.shrink'});
    final plan = server<PlanMsg>({
      't': 'plan',
      'plan': {
        'wing': 2,
        'labels': {
          'desk-17': {'text': 'Infra', 'color': '#2b2d42', 'by': 'ada', 'at': 3},
        },
      },
    });
    expect(plan.plan.labels['desk-17']!.text, 'Infra');
  });

  test('settings: the map, the real-time sky, the dog breed and coat', () {
    final map = server<MapMsg>({
      't': 'map',
      'state': {
        'pick': 'station',
        'custom': [
          {'file': 'x.json', 'error': 'it needs an id'},
        ],
        'by': 'ada',
        'at': 9,
      },
    });
    expect(map.state.pick, 'station');
    client(const MapSetCmd('castle'), {'t': 'map.set', 'map': 'castle'});
    client(const MapSetCmd(), {'t': 'map.set'});
    client(const SkyClockCmd(true), {'t': 'sky.clock', 'real': true});
    final sky = server<SkyMsg>({
      't': 'sky',
      'state': {'lat': 1, 'lon': 2, 'utcOffset': 60, 'weather': 'clear', 'intensity': 0, 'realTime': true},
    });
    expect(sky.state.realTime, isTrue);
    client(const DogBreedCmd('pomeranian'), {'t': 'dog.breed', 'breed': 'pomeranian'});
    client(const DogCoatCmd(6), {'t': 'dog.coat', 'coat': 6});
    final dog = server<DogMsg>({
      't': 'dog',
      'dog': {
        'name': 'Biscuit',
        'coat': 6,
        'breed': 'pomeranian',
        'path': [
          [0, 0],
        ],
        'speed': 0,
        'elapsed': 0,
        'act': 'sit',
      },
    });
    expect(dog.dog.breed, DogBreed.pomeranian);
    // A breed this page doesn't know (a newer office's) is the pup.
    expect(dogBreed('dragon'), DogBreed.pup);
    expect(dogCoats.length, dogCoatNames.length);
    expect(dogCoatGlow.length, dogCoats.length);
    server<SitRefusedMsg>({'t': 'sit.refused', 'seat': 'couch:0', 'by': 'Bo'});
  });

  test('team and services say how the office was deployed, and its Tailscale name', () {
    server<TeamMsg>({
      't': 'team',
      'state': {
        'ssh': 'ssh://office@host:2222',
        'port': 4000,
        'deploy': 'deploy/azure.sh --name x',
        'members': [],
        'tailnet': 'agent-office.tail1234.ts.net',
      },
    });
    server<ServicesMsg>({
      't': 'services',
      'state': {
        'items': [],
        'port': 4000,
        'deploy': 'deploy/fly.sh',
        'ssh': 'office@1.2.3.4',
        'tailnet': 'office.ts.net',
      },
    });
  });

  test('issues a worker just took, queue tasks and meetings on their owner’s sign-ins, and no meeting budget', () {
    server<GhIssuesMsg>({
      't': 'gh.issues',
      'state': {
        'items': [
          {
            'number': 4,
            'title': 'x',
            'state': 'OPEN',
            'url': 'u',
            'author': 'a',
            'labels': [],
            'assignees': [],
            'taken': true,
            'createdAt': 'c',
            'updatedAt': 'u',
            'body': '',
            'comments': 0,
          },
        ],
        'fetchedAt': 1,
        'loading': false,
      },
    });
    final task = QueueTask.fromJson({
      'id': 't1',
      'title': 'x',
      'prompt': 'p',
      'addedBy': 'ada',
      'owner': 'acct-1',
      'addedAt': 1,
      'status': 'queued',
    });
    expect(task.owner, 'acct-1');
    expect(task.toJson()['owner'], 'acct-1');
    // An older page still sends a budget: it's ignored.
    final start = ClientMsg.parse({
      't': 'meeting.start',
      'pattern': 'debate',
      'prompt': 'p',
      'roles': [],
      'budget': 100000,
    });
    expect((start as MeetingStartCmd).toJson().containsKey('budget'), isFalse);
  });

  test('welcome carries the map, and the floor its plan, cars and jail', () {
    final w = ServerMsg.parse({'t': 'welcome'}) as WelcomeMsg;
    expect(w.map.pick, 'office');
    expect(w.view.plan.wing, 0);
    expect(w.view.cars, isEmpty);
    expect(w.view.jail.bones, 0);
    final json = _json(w.toJson());
    expect(json['map'], {'pick': 'office', 'custom': []});
    expect(json['jail'], {'prisoners': [], 'bones': 0});
    expect(json['plan'], {'wing': 0, 'labels': {}});
  });

  test('every message type upstream sends or takes has a class here', () {
    const serverTypes = [
      'toss', 'sit.refused', 'signins', 'signins.needed', 'cars', 'car.move', 'car.honk', 'map', 'plan', //
    ];
    for (final t in serverTypes) {
      expect(ServerMsg.parse({'t': t}), isNot(isA<UnknownMsg>()), reason: t);
    }
    const clientTypes = [
      'toss', 'signins.get', 'signins.start', 'signins.code', 'signins.cancel', 'signins.token', 'signins.office', //
      'signins.signout', 'worker.rebuild', 'car.enter', 'car.leave', 'car.drive', 'car.honk', 'map.set', 'desk.label',
      'floor.expand', 'floor.shrink', 'floor.cancel', 'dog.breed', 'dog.coat', 'sky.clock',
    ];
    for (final t in clientTypes) {
      expect(ClientMsg.parse({'t': t}), isNot(isA<UnknownCmd>()), reason: t);
    }
  });
}
