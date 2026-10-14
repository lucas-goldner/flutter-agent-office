// The 2D view's lines (lite/lite_logic.dart): each worker card's task, what it's doing and the rest; the floor
// switcher's; and which workers just started waiting. Plus where signing in goes back to.

import 'package:agent_office/interop/browser.dart' show loginNext, loginUrl;
import 'package:agent_office/lite/lite_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof;

import '../ui/harness.dart';

WorkerInfo worker(String id, {String status = 'working', Map<String, dynamic> extra = const {}, bool acked = true}) =>
    WorkerInfo.fromJson({...workerJson(id, status: status, acked: acked), ...extra});

FloorInfo floor(String id, {int waiting = 0, bool cloning = false, int people = 0}) =>
    FloorInfo.fromJson({...floorJson(id, id, waiting: waiting, people: people), if (cloning) 'cloning': true});

void main() {
  test('a floor says who is waiting there, or how its clone is going', () {
    expect(liteFloorLabel(floor('api')), 'api');
    expect(liteFloorLabel(floor('api', waiting: 2)), 'api · 🙋 2');
    expect(liteFloorLabel(floor('api', cloning: true, waiting: 2)), startsWith('api (⏳ '));
  });

  test('the line under the floor: branch, repository and who is there', () {
    const p = ProjectInfo(
      name: 'api',
      dir: '/w/api',
      branch: 'main',
      agentCmd: 'claude',
      defaultProvider: AgentProvider.claude,
      agentProviders: [AgentProvider.claude],
    );
    expect(liteFloorMeta(project: p, floor: floor('api', people: 3), anyFloors: true), '⎇ main · acme/api · 👥 3 here');
    expect(liteFloorMeta(project: p, anyFloors: true), '⎇ main · /w/api');
    expect(liteFloorMeta(anyFloors: true), '');
    expect(liteFloorMeta(anyFloors: false), 'Add a project from the elevator in the 3D office.');
  });

  test('other floors with someone waiting, not this one or one still cloning', () {
    final floors = [floor('a', waiting: 1), floor('b', waiting: 2), floor('c'), floor('d', waiting: 1, cloning: true)];
    expect(waitingElsewhere(floors, 'a').map((f) => f.id), ['b']);
  });

  test('off the roof to the first floor that is there', () {
    final floors = [floor('a', cloning: true), floor('b')];
    expect(offTheRoof(roof, floors), 'b');
    expect(offTheRoof('a', floors), isNull);
    expect(offTheRoof(roof, [floor('a', cloning: true)]), isNull);
  });

  test('what a worker is on and what it is doing, in a line each', () {
    expect(liteTask(worker('1', extra: {'title': 'Fix login'})), 'Fix login');
    expect(liteTask(worker('1', extra: {'prompt': 'x' * 120}))!.length, 90);
    expect(liteNow(worker('1', status: 'needs_input', extra: {'activity': 'Allow Bash?'})), '🙋 Allow Bash?');
    expect(liteNow(worker('1', status: 'needs_input')), '🙋 Waiting on an answer');
    expect(liteNow(worker('1', status: 'exited')), '💤 Asleep: open it to wake it up');
    expect(
      liteNow(
        worker(
          '1',
          status: 'done',
          extra: {
            'task': {'name': 'Login', 'summary': 'Fixed it'},
          },
        ),
      ),
      '✅ Fixed it',
    );
    expect(liteNow(worker('1', status: 'done')), isNull);
    expect(liteNow(worker('1', extra: {'activity': 'Reading files'})), 'Reading files');
    final lost = worker(
      '1',
      extra: {
        'worktree': {'path': '/w/.wt/a', 'branch': 'a'},
        'lost': {'branch': 'a'},
      },
    );
    expect(liteNow(lost), startsWith('🌿 Its worktree was deleted'));
    expect(liteCanPrompt(lost), isFalse);
  });

  test('its engine, desk, branch and PR', () {
    final w = worker(
      '1',
      extra: {
        'worktree': {'path': '/w/.wt/fix', 'branch': 'fix'},
        'pr': {'number': 12, 'url': 'https://x/12', 'state': 'OPEN'},
      },
    );
    final sub = liteSub(w, null);
    expect(sub, contains('🌿 fix'));
    expect(sub, contains('🔀 PR #12'));
    expect(sub, startsWith('⚙️ '));
    expect(liteSub(WorkerInfo.fromJson({...workerJson('2'), 'kind': 'shell'}), null), startsWith('🐚 shell'));
  });

  test('a prompt for one at work, not one asleep or asking something', () {
    expect(liteCanPrompt(worker('1')), isTrue);
    expect(liteCanPrompt(worker('1', status: 'needs_input')), isFalse);
    expect(liteCanPrompt(worker('1', status: 'exited')), isFalse);
  });

  test('only a change to waiting on someone counts, and not the first sight of one', () {
    final last = <String, WorkerStatus>{};
    expect(newlyWaiting([worker('1', status: 'needs_input')], last), isEmpty);
    expect(newlyWaiting([worker('1', status: 'needs_input')], last), isEmpty);
    expect(newlyWaiting([worker('1')], last), isEmpty);
    expect(newlyWaiting([worker('1', status: 'done', acked: false)], last).single.id, '1');
    expect(newlyWaiting([worker('1', status: 'needs_input')], last).single.id, '1');
  });

  test('signing in goes back to the 2D view when that is where you were', () {
    expect(loginUrl('/lite'), '/login?next=/lite');
    expect(loginUrl('/'), '/login');
    expect(loginNext({'next': '/lite'}), '/lite');
    expect(loginNext({'next': 'https://evil.example'}), '/');
    expect(loginNext({}), '/');
  });
}
