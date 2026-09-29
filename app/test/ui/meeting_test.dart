import 'dart:ui' as ui;

import 'package:agent_office/ui/meeting.dart';
import 'package:agent_office/world/meeting.dart';
import 'package:agent_office/world/office/meeting_room.dart';
import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart';

Meeting meeting({MeetingStatus status = MeetingStatus.running, String? preview}) => Meeting(
  id: 'm1',
  pattern: MeetingPattern.debate,
  title: 'A* or a navmesh?',
  prompt: 'Should the dog use A* or a navmesh?',
  output: 'decisions/dog-nav.md',
  seats: const [
    MeetingSeat(role: 'Chair', deskId: 'meeting-1', workerName: 'Ada'),
    MeetingSeat(role: 'Skeptic', deskId: 'meeting-2', workerName: 'Grace'),
  ],
  rounds: 3,
  round: 2,
  step: 0,
  turns: const [
    MeetingTurn(seat: 1, doing: 'critiquing', file: 'a.md', state: MeetingTurnState.working),
    MeetingTurn(seat: 0, doing: 'critiquing', file: 'b.md', state: MeetingTurnState.done),
  ],
  budget: 2000000,
  tokens: 1500000,
  cost: 1.25,
  costKnown: true,
  status: status,
  calledBy: 'Ada',
  startedAt: 0,
  notes: '.meeting/m1',
  preview: preview,
);

void main() {
  test('who has the floor, and the round', () {
    final m = meeting();
    expect(speaking(m), ['Skeptic']);
    expect(meetingStage(m), 'Round 2 of 3 · critiquing');
  });

  test('the form asks for what the pattern needs', () {
    ({MeetingRequest? request, String? problem}) ask(
      MeetingPattern p, {
      String prompt = 'why?',
      String parts = '',
      int? pr,
    }) => meetingRequest(
      pattern: p,
      prompt: prompt,
      title: '',
      output: 'out/why.md',
      roles: const ['Lead', 'A', 'B'],
      parts: parts,
      pr: pr,
      budgetThousands: 3000,
    );
    expect(ask(MeetingPattern.debate, prompt: ' ').problem, isNotNull);
    expect(ask(MeetingPattern.review).problem, 'Pick a pull request');
    expect(ask(MeetingPattern.review, pr: 12).request!.pr, 12);
    expect(ask(MeetingPattern.mapreduce, parts: 'src/').problem, contains('at least 2 parts'));
    final ok = ask(MeetingPattern.mapreduce, parts: 'src/\n\n lib/ ').request!;
    expect(ok.parts, ['src/', 'lib/']);
    expect(ok.budget, 3000000);
    expect(ok.title, isNull);
    expect(ok.toJson()['pattern'], 'mapreduce');
  });

  test('the board and the sign paint, free, running and done', () {
    for (final s in [
      const MeetingState(),
      MeetingState(current: meeting()),
      MeetingState(current: meeting(preview: '# Decision\n\nUse **A*** with `grid` cells.\n\n## Why\nIt is simple.')),
      MeetingState(current: meeting(status: MeetingStatus.done)),
      MeetingState(current: meeting(status: MeetingStatus.stopped)),
    ]) {
      for (final paint in [paintMeetingBoard, paintMeetingSign]) {
        final rec = ui.PictureRecorder();
        paint(ui.Canvas(rec), s);
        rec.endRecording().dispose();
      }
    }
  });

  test('the glass leaves the door open, and the table blocks its top', () {
    final cs = meetingColliders();
    const doorX = (10.0 + 11.4) / 2;
    final z = MeetingRoom.minZ;
    expect(cs.where((c) => doorX > c.minX && doorX < c.maxX && z >= c.minZ && z <= c.maxZ), isEmpty);
    expect(cs.any((c) => c.top == MeetingTable.height), isTrue);
  });

  testWidgets('the window calls a meeting, and then shows how it goes', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ModalStack.instance.attach(Overlay.of(context));
            return const SizedBox();
          },
        ),
      ),
    );
    final store = Store();
    final sent = <ClientMsg>[];
    final modal = openMeeting(store: store, send: sent.add, openTerminal: (_) {});
    await tester.pump();
    expect(find.text('🤝 Call a meeting'), findsOneWidget);
    expect(find.text('🗣️ Debate'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Should the dog use A* or a navmesh?');
    await tester.pump();
    await tester.tap(find.text('🤝 Start the meeting'));
    await tester.pump();
    expect(sent.single, isA<MeetingStartCmd>());
    final req = (sent.single as MeetingStartCmd).request;
    expect(req.roles.length, 3);
    expect(req.output, startsWith('docs/decisions/should-the-dog'));
    expect(modal.closed, isTrue);

    store.apply(MeetingMsg(MeetingState(current: meeting())));
    openMeeting(store: store, send: sent.add, openTerminal: (_) {});
    await tester.pump();
    expect(find.text('🤝 Meeting room'), findsOneWidget);
    expect(find.textContaining('Round 2 of 3'), findsOneWidget);
    ModalStack.instance.closeAll();
    await tester.pump(const Duration(seconds: 5));
  });
}
