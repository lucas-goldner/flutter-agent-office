import 'package:agent_office/world/worker_acts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/actions.dart';
import 'package:office_shared/protocol.dart';

void main() {
  group('pickAct', () {
    test('a working worker acts out its latest tool call, or types', () {
      Act act(WorkerAction? a) => pickAct(status: WorkerStatus.working, hopping: false, bouncing: false, action: a);
      expect(act(null), Act.type);
      expect(act(WorkerAction.read), Act.read);
      expect(act(WorkerAction.edit), Act.edit);
      expect(act(WorkerAction.test), Act.test);
      expect(act(WorkerAction.web), Act.web);
      expect(act(WorkerAction.failing), Act.failing);
    });

    test('from a tool call to what it looks like', () {
      Act fromTool(String tool, [Object? input]) =>
          pickAct(status: WorkerStatus.working, hopping: false, bouncing: false, action: toolAction(tool, input));
      expect(fromTool('Read'), Act.read);
      expect(fromTool('Edit'), Act.edit);
      expect(fromTool('WebSearch'), Act.web);
      expect(fromTool('Bash', {'command': 'npm test'}), Act.test);
      expect(fromTool('Bash', {'command': 'git log -5'}), Act.read);
      expect(fromTool('Bash', {'command': 'rm -rf build'}), Act.type);
    });

    test('hopping, waiting on you and resting win over the tool call', () {
      expect(pickAct(status: WorkerStatus.working, hopping: true, bouncing: false, action: WorkerAction.read), Act.up);
      expect(pickAct(status: WorkerStatus.done, hopping: false, bouncing: true), Act.up);
      expect(
        pickAct(status: WorkerStatus.needsInput, hopping: false, bouncing: true, action: WorkerAction.edit),
        Act.waiting,
      );
      expect(pickAct(status: WorkerStatus.idle, hopping: false, bouncing: false, action: WorkerAction.web), Act.rest);
      expect(pickAct(status: WorkerStatus.offline, hopping: false, bouncing: false), Act.rest);
    });
  });

  test('stances: papers up to read, leaning back for tests, head in hands failing', () {
    final read = stanceOf(Act.read, 0);
    expect(read.armLx, -2.05);
    expect(read.lean, lessThan(0));
    final test = stanceOf(Act.test, 0);
    expect(test.armLx, -3.3);
    expect(test.lean, -0.32);
    expect(test.kick, greaterThan(0));
    final failing = stanceOf(Act.failing, 0);
    expect(failing.reach, 1);
    expect(failing.lean, greaterThan(0.3));
    expect(failing.lid, lessThan(1));
    final waiting = stanceOf(Act.waiting, 0.1);
    expect(waiting.armLz, 1);
    expect(waiting.armRz, -1);
    expect(stanceOf(Act.rest, 0).armLx, -0.3);
  });

  test('ActionTimer: quick tool calls do not flicker, and despair lasts', () {
    final a = ActionTimer()..next = WorkerAction.read;
    expect(a.step(kActMin), WorkerAction.read);
    a.next = WorkerAction.edit;
    expect(a.step(0.5), WorkerAction.read);
    a.next = WorkerAction.web;
    expect(a.step(0.5), WorkerAction.read);
    expect(a.step(0.3), WorkerAction.web);
    a.next = WorkerAction.failing;
    expect(a.step(kActMin), WorkerAction.failing);
    a.next = null;
    expect(a.step(kActMin), WorkerAction.failing);
    expect(a.step(kDespairMin), isNull);
  });

  test('StanceBlend eases from one act into the next, and the old one drops out', () {
    final b = StanceBlend();
    b.pose(Act.rest, 1, 0);
    expect(b.weight(Act.rest), 1);
    final mid = b.pose(Act.up, 0.05, 0);
    expect(mid.armLx, inExclusiveRange(-2.6, -0.3));
    for (var i = 0; i < 100; i++) {
      b.pose(Act.up, 0.05, 0);
    }
    expect(b.weight(Act.rest), 0);
    expect(b.weight(Act.up), closeTo(1, 1e-6));
    expect(b.pose(Act.up, 0.05, 0).armLx, closeTo(-2.6, 1e-6));
  });

  group('the dance party', () {
    test('hops up, dances eight beats and hops back down', () {
      expect(danceAt(0).on, 0);
      expect(danceAt(kDanceUp / 2).arc, closeTo(kHop, 1e-9));
      final groove = danceAt(kDanceUp + kBeat * 0.5);
      expect(groove.on, 1);
      expect(groove.lift, closeTo(0.12, 1e-9));
      final twirl = danceAt(kDanceUp + kBeat * 5);
      expect(twirl.armZ, [-1.35, 1.35]);
      final jump = danceAt(kDanceUp + kBeat * 6.5);
      expect(jump.lift, closeTo(0.45, 1e-9));
      expect(danceAt(kDanceTime).on, 0);
      expect(kDanceTime, closeTo(1 + 8 * 60 / 140, 1e-9));
    });

    test('a second merge keeps it up there', () {
      expect(danceAgain(kDanceUp + 2), kDanceUp);
      expect(danceAgain(0.2), 0.2);
      // Halfway down, it goes back up from where it is in the air.
      expect(danceAgain(kDanceUp + kDanceMoves + kDanceDown / 2), closeTo(kDanceUp / 2, 1e-9));
    });
  });
}
