// A worker across repositories (#173): hiring one, its pull requests, its changes per repository, and
// sending it home.

import 'package:agent_office/ui/changes.dart';
import 'package:agent_office/ui/prompt.dart';
import 'package:agent_office/ui/prompt_logic.dart';
import 'package:agent_office/ui/repos.dart';
import 'package:agent_office/ui/terminal_logic.dart';
import 'package:agent_office/ui/hud.dart' show workerSub;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

Map<String, dynamic> acrossJson({bool prs = false, bool opening = false, String status = 'done'}) => {
  ...workerJson('w1', status: status),
  'worktree': {'path': '.agent-office/worktrees/ada/app', 'branch': 'office/ada', 'base': 'abc'},
  if (prs) 'pr': {'number': 12, 'url': 'https://github.com/acme/app/pull/12'},
  'prOpening': ?(opening ? true : null),
  'repos': [
    {
      'floor': 'f2',
      'name': 'api',
      'dir': '/w/api',
      'path': '.agent-office/worktrees/ada/api',
      'branch': 'office/ada',
      'base': 'def',
    },
  ],
};

void main() {
  test('its repositories, its own floor’s first, and what O says at its desk', () {
    final w = WorkerInfo.fromJson(acrossJson());
    expect(workerRepos(w).map((r) => (r.floor, r.name)), [(null, 'app'), ('f2', 'api')]);
    expect(workerRepoFolders(w), ['app', 'api']);
    expect(reposKey(w, ready: true), (key: true, text: 'Open PRs (2 repos)'));
    expect(reposKey(w, ready: false), isNull);
    expect(reposKey(WorkerInfo.fromJson(acrossJson(prs: true)), ready: true), (key: true, text: '1 of 2 PRs'));
    expect(reposKey(WorkerInfo.fromJson(acrossJson(opening: true)), ready: true), (key: false, text: '⏳ Opening PRs…'));
    expect(workerSub(w, null), contains('🗂️ 2 repos'));
    expect(terminalTitle(w, null), endsWith('🗂️ app + api'));
    final single = WorkerInfo.fromJson({
      ...workerJson('w2'),
      'worktree': {'path': 'x', 'branch': 'b', 'base': 'c'},
    });
    expect(workerRepoFolders(single), isNull);
  });

  test('sending one home: the choices and a line for each worktree', () {
    final choices = cleanupChoices('p', 'office/ada', ['app', 'api']);
    expect(choices.first.$3, 'Removes its worktrees of app, api, and office/ada in each.');
    expect(choices.last.$2, 'Keep them all');
    expect(cleanupChoices('p', 'b').first.$2, 'Delete the worktree and its branch');
    final report = worktreeReport(
      WorktreeState.fromJson({
        'exists': true,
        'dirty': 1,
        'ahead': 0,
        'unpushed': 0,
        'repos': [
          {
            'name': 'app',
            'state': {'exists': true, 'dirty': 1, 'ahead': 0, 'unpushed': 0},
          },
          {
            'name': 'api',
            'state': {'exists': true, 'dirty': 0, 'ahead': 2, 'unpushed': 0},
          },
        ],
      }),
      'office/ada',
    );
    expect(report.lines, [
      '⚠️ app: 1 uncommitted change in the worktree — deleting it loses them.',
      'api: 2 commits on office/ada, all pushed or merged.',
    ]);
    expect(report.risky, isTrue);
  });

  testWidgets('hiring: 🗂️ Also work in ticks the worktree, and unticking it clears them', (tester) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox());
    PromptChoice? got;
    openPrompt(
      PromptOptions(
        title: 'Hire',
        allowEmpty: true,
        worktreeOption: true,
        repoOptions: const [(id: 'f2', name: 'api'), (id: 'f3', name: 'web')],
        onSubmit: (_, o) => got = o,
      ),
    );
    await tester.pump();
    expect(find.text('🗂️ Also work in'), findsOneWidget);
    // The worktree box off first.
    final wt = find.text('🌿 Work in its own git worktree & branch');
    final cb = tester.widget<Checkbox>(
      find.descendant(
        of: find.ancestor(of: wt, matching: find.byType(Row)).first,
        matching: find.byType(Checkbox),
      ),
    );
    if (cb.value == true) {
      await tester.tap(wt);
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('repo-pick-f2')));
    await tester.pump();
    await tester.tap(find.text('Send ✨'));
    await tester.pump();
    expect(got!.worktree, isTrue, reason: 'picking a project ticks the worktree');
    expect(got!.repos, ['f2']);
  });

  testWidgets('the Changes window has a tab per repository, each followed on its own', (tester) async {
    final office = Office()..welcome();
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': acrossJson()}));
    await office.pump(tester, const SizedBox());
    openChanges(office.scope(), 'w1');
    await tester.pump();
    expect(office.net.sent.whereType<ChangesWatchCmd>().single.repo, isNull);
    expect(find.text('📁 app'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('changes-tab-f2')));
    await tester.pump();
    expect(office.net.sent.whereType<ChangesUnwatchCmd>().single.repo, isNull);
    expect(office.net.sent.whereType<ChangesWatchCmd>().last.repo, 'f2');
    // Opened again on its own floor's repository: the same window switches.
    openChanges(office.scope(), 'w1');
    await tester.pump();
    expect(office.net.sent.whereType<ChangesWatchCmd>().last.repo, isNull);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets("O once it has a PR: each repository's, and the missing ones", (tester) async {
    final office = Office()..welcome(floors: [floorJson('f1', 'app'), floorJson('f2', 'api')]);
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': acrossJson(prs: true)}));
    await office.pump(tester, const SizedBox());
    var missing = 0;
    String? changesOf = 'none';
    openRepoPulls(
      office.scope(),
      'w1',
      RepoPullsActions(openPull: (_, _) {}, openMissing: () => missing++, changes: (r) => changesOf = r),
    );
    await tester.pump();
    expect(find.text("🔀 Ww1's pull requests"), findsOneWidget);
    expect(find.text('🔀 #12'), findsOneWidget);
    expect(find.text('No PR yet'), findsOneWidget);
    expect(find.text('api floor'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-missing-prs')));
    expect(missing, 1);
    await tester.tap(find.text('🌿 Changes').last);
    await tester.pump();
    expect(changesOf, 'f2');
  });
}
