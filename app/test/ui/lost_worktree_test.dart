// A worker whose worktree was deleted outside the office (#197): what the dialog says, and its buttons.

import 'package:agent_office/office/carry.dart';
import 'package:agent_office/ui/prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void main() {
  test('what happened to the branch', () {
    expect(
      lostWorktreeWhat('Ada', 'office/ada', LostBranch.here),
      startsWith('Its branch 🌿 office/ada is still here.'),
    );
    expect(lostWorktreeWhat('Ada', 'b', LostBranch.origin), contains("checks origin's copy out again"));
    expect(lostWorktreeWhat('Ada', 'b', LostBranch.gone), contains('the work on it is gone'));
    final w = WorkerInfo.fromJson({
      ...workerJson('w1', status: 'offline'),
      'worktree': {'path': '/w/.agent-office/worktrees/ada', 'branch': 'office/ada'},
      'lost': {'branch': 'here'},
    });
    expect(cantTakeCard(w), "Ww1's worktree was deleted — press E at its desk to fix it");
  });

  testWidgets('rebuild one, or all of them', (tester) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox());
    final rebuilt = <bool>[];
    var home = 0;
    lostWorktreeDialog(
      LostWorktreeOptions(
        name: 'Ada',
        worktree: (path: '/w/x', branch: 'office/ada'),
        lost: LostBranch.here,
        others: const ['Bo'],
        rebuild: rebuilt.add,
        sendHome: () => home++,
      ),
    );
    await tester.pump();
    expect(find.text("🌿 Ada's worktree was deleted"), findsOneWidget);
    expect(find.textContaining('1 other worker on this floor lost its worktree too: Bo.'), findsOneWidget);
    await tester.tap(find.text('Rebuild all 2'));
    await tester.pump();
    expect(rebuilt, [true]);
    expect(home, 0);
  });
}
