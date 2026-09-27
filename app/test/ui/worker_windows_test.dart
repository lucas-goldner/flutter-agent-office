// The words and rules of the worker windows: labels, provider rules, the changes diff reader, the
// send-home report, the queue's lines and the search marks.

import 'package:agent_office/shared/protocol.dart';
import 'package:agent_office/ui/changes_logic.dart';
import 'package:agent_office/ui/child_button.dart';
import 'package:agent_office/ui/prompt_logic.dart';
import 'package:agent_office/ui/provider.dart';
import 'package:agent_office/ui/queue_logic.dart';
import 'package:agent_office/ui/search_logic.dart';
import 'package:agent_office/ui/theme.dart';
import 'package:agent_office/ui/worker_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectInfo project({String def = 'claude', List<String> providers = const ['claude', 'opencode']}) =>
    ProjectInfo.fromJson({'name': 'p', 'dir': '/p', 'agentCmd': 'claude', 'defaultProvider': def, 'agentProviders': providers});

WorkerInfo worker(Map<String, dynamic> extra) => WorkerInfo.fromJson({
  'id': 'w1',
  'kind': 'agent',
  'deskId': 'desk-1',
  'name': 'Nova',
  'color': '#ff8a5b',
  'status': 'working',
  'acked': true,
  'createdBy': 'Ada',
  'createdAt': 0,
  'cols': 80,
  'rows': 24,
  'viewers': [],
  ...extra,
});

const usage = {'input': 1200, 'output': 800, 'cacheWrite': 0, 'cacheRead': 36000, 'cost': 0.42, 'calls': 3};

void main() {
  group('labels', () {
    test('status words and hex colours', () {
      expect(statusLabel(WorkerStatus.idle), 'ready');
      expect(statusLabel(WorkerStatus.offline), 'asleep');
      expect(statusLabel(WorkerStatus.needsInput), 'needs input');
      expect(hexColor('#ff8a5b'), const Color(0xFFFF8A5B));
      expect(hexColor('#abc'), const Color(0xFFAABBCC));
      expect(hexColor('nope'), const Color(0xFF888888));
    });

    test('usage figures', () {
      expect(fmtTokens(950), '950');
      expect(fmtTokens(1500), '1.5k');
      expect(fmtTokens(38000), '38k');
      expect(fmtTokens(2500000), '2.50M');
      expect(fmtCost(0.004), r'<$0.01');
      expect(fmtCost(1234.5), r'$1,234.50');
      final u = Usage.fromJson(usage);
      expect(usageLabel(u), r'$0.42 · 38k tokens');
      expect(usageLabel(u, AgentProvider.opencode), r'$0.42 reported · 38k tokens');
      expect(usageLabel(u, AgentProvider.codex), 'cost unavailable · 38k tokens');
      expect(usageTitle(u).split('\n').first, r'$0.42 over 3 API calls');
    });

    test('the terminal header cost', () {
      expect(workerCostText(worker({'usage': usage}), null), r'$0.42 · 38k tokens');
      expect(workerCostText(worker({'provider': 'opencode'}), null), 'waiting for metrics');
      expect(workerCostText(worker({'provider': 'codex'}), null), 'waiting for first report');
      expect(workerCostText(worker({'provider': 'custom'}), null), 'usage untracked');
      expect(workerCostText(worker({'kind': 'shell'}), null), '');
      expect(workerCostTitle(worker({'provider': 'opencode'}), null), providerUsageNote(AgentProvider.opencode));
    });
  });

  group('providers', () {
    test('supported, resolved and labelled from the project', () {
      expect(supportedProviders(null), [AgentProvider.claude]);
      expect(supportedProviders(project(providers: ['opencode', 'opencode', 'codex'])), [AgentProvider.opencode, AgentProvider.codex]);
      expect(supportedProviders(project(def: 'codex', providers: [])), [AgentProvider.codex]);
      expect(resolvedProvider(null, project(def: 'opencode')), AgentProvider.opencode);
      expect(resolvedProvider(AgentProvider.codex, project()), AgentProvider.codex);
      expect(providerLabel(null, null), 'Claude Code');
    });

    test('OpenCode model ids', () {
      expect(validModel('anthropic/claude-sonnet-4'), isTrue);
      expect(validModel('openrouter/meta/llama-3'), isTrue);
      expect(validModel('nomodel'), isFalse);
      expect(validModel('a/'), isFalse);
      expect(validModel('-bad/x'), isFalse);
      expect(validModel('a b/c'), isFalse);
      expect(validModel('a/b​'), isFalse);
      expect(validModel('a/${'x' * 300}'), isFalse);
    });

    test('the picker controller reports a bad model', () {
      final c = ProviderPickerController(project());
      c.selected = AgentProvider.opencode;
      c.modelText.text = 'not a model';
      expect(c.valid(), isFalse);
      expect(c.modelError, isNotNull);
      expect(c.model(), isNull);
      c.modelText.text = 'anthropic/x';
      expect(c.valid(), isTrue);
      expect(c.model(), 'anthropic/x');
      c.selected = AgentProvider.claude;
      expect(c.model(), isNull);
      expect(c.value(), AgentProvider.claude);
    });
  });

  group('changes', () {
    test('parseDiff: meta, hunks, line numbers, truncation', () {
      const diff =
          'diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -3,2 +3,3 @@ fn\n ctx\n-old\n+new\n+more\n\\ No newline at end of file\n';
      final rows = parseDiff(diff, true);
      expect(rows.map((r) => r.kind).toList(), [DiffKind.hunk, DiffKind.ctx, DiffKind.del, DiffKind.add, DiffKind.add, DiffKind.meta, DiffKind.meta]);
      expect(rows[1], (kind: DiffKind.ctx, old: '3', now: '3', code: 'ctx'));
      expect(rows[2], (kind: DiffKind.del, old: '4', now: '', code: 'old'));
      expect(rows[4], (kind: DiffKind.add, old: '', now: '5', code: 'more'));
      expect(rows.last.code, '… the rest of this diff is too long to show here');
      expect(parseDiff('Binary files differ\n', false).single.kind, DiffKind.meta);
    });

    test('headings, branch line and footer bits', () {
      ChangesState s(Map<String, dynamic> j) =>
          ChangesState.fromJson({'workerId': 'w1', 'dir': '', 'base': 'main', 'ahead': 0, 'more': 0, 'at': 0, 'files': [], ...j});
      const f = {'path': 'a.ts', 'status': 'M', 'additions': 1, 'deletions': 0, 'binary': false, 'uncommitted': true, 'sig': 's'};
      expect(filesHeading(null), 'Changed files');
      expect(
        filesHeading(
          s({
            'files': [f],
          }),
        ),
        '1 changed file',
      );
      expect(
        filesHeading(
          s({
            'files': [f],
            'more': 3,
          }),
        ),
        '1+ changed files',
      );
      expect(branchLine(s({'branch': 'nova/x'})), '🌿 nova/x · vs main');
      expect(branchLine(s({'branch': 'main', 'base': 'HEAD'})), '🌿 main · uncommitted changes');
      expect(branchLine(s({'error': 'boom'})), '');
      expect(whereText(s({})), 'the project folder');
      expect(commitLabel(2), '✅ Commit 2 files…');
      expect(commitLabel(0), '✅ Commit…');
      expect(statusLetter(ChangeStatus.untracked), 'A');
      final shared = s({
        'files': [f],
        'ahead': 2,
        'prBase': 'main',
        'branch': 'nova/x',
      });
      expect(summaryBits(shared).map((b) => b.text).toList(), ['1 uncommitted', '2 commits ahead of main', '📁 shared project folder']);
      expect(prBlocked(shared), 'Commit first');
      expect(prBlocked(s({'prBase': 'main', 'branch': 'nova/x'})), 'Nothing on nova/x that main lacks yet');
      expect(prBlocked(s({'prBase': 'main', 'branch': 'nova/x', 'ahead': 1})), '');
    });
  });

  test('send home: what deleting the worktree would lose', () {
    WorktreeState st(Map<String, dynamic> j) => WorktreeState.fromJson({'exists': true, 'dirty': 0, 'ahead': 0, 'unpushed': 0, ...j});
    final clean = worktreeReport(st({}), 'b');
    expect(clean.lines, ['Nothing on the branch yet and a clean worktree: safe to delete.']);
    expect(clean.risky, isFalse);
    expect(worktreeReport(st({'ahead': 2}), 'b').lines, ['2 commits on b, all pushed or merged.']);
    final risky = worktreeReport(st({'dirty': 1, 'unpushed': 3}), 'b');
    expect(risky.risky, isTrue);
    expect(risky.lines, [
      '⚠️ 1 uncommitted change in the worktree — deleting it loses them.',
      '⚠️ 3 commits on b that no remote has — deleting the branch loses them.',
    ]);
    expect(worktreeReport(st({'error': 'the office did not answer'}), 'b').lines, ["Couldn't check the worktree: the office did not answer."]);
    expect(worktreeReport(st({'exists': false}), 'b').lines, ['The worktree folder is already gone.']);
    expect(kCleanupLabel[WorktreeCleanup.all], 'Send home & delete both');
  });

  group('queue', () {
    QueueTask task(Map<String, dynamic> j) => QueueTask.fromJson({
      'id': 't',
      'title': 'Fix it',
      'prompt': 'p',
      'addedBy': 'Ada',
      'addedAt': DateTime.now().millisecondsSinceEpoch,
      'status': 'queued',
      ...j,
    });

    test('titles, outcomes, PR labels', () {
      expect(taskTitleText(task({'issue': 4})), '#4 Fix it');
      expect(taskTitleText(task({'issue': 4, 'title': '#4 Fix it'})), '#4 Fix it');
      expect(taskOutcome(task({'outcome': 'failed'})), "couldn't start: unknown error");
      expect(taskOutcome(task({'outcome': 'exited', 'error': 'crash'})), 'stopped: crash');
      expect(taskOutcome(task({'outcome': 'done'})), 'finished, no PR found yet');
      expect(taskPrLabel(QueueTaskPr.fromJson({'number': 9, 'url': 'u', 'state': 'MERGED', 'title': 't'})), '🔀 PR #9 ✓');
      expect(taskPrLabel(QueueTaskPr.fromJson({'number': 9, 'url': 'u', 'state': 'DRAFT', 'title': 't'})), '🔀 PR #9 (draft)');
    });

    test('meta lines', () {
      expect(taskMeta(task({'provider': 'opencode', 'model': 'a/b'})), '⚙️ OpenCode · initial: a/b · waiting for metrics · added by Ada just now');
      final running = task({'status': 'running', 'workerId': 'w1', 'workerName': 'Nova', 'branch': 'nova/x'});
      expect(taskMeta(running, w: worker({'usage': usage})), '⚙️ Claude Code · Nova · working · 🌿 nova/x · by Ada');
      expect(taskMeta(running), '⚙️ Claude Code · Nova · gone · 🌿 nova/x · by Ada');
    });
  });

  group('search', () {
    test('marks every match, whitespace collapsed', () {
      expect(highlight('Fix  the LOGIN\tbutton login', 'login'), [
        (text: 'Fix the ', mark: false),
        (text: 'LOGIN', mark: true),
        (text: ' button ', mark: false),
        (text: 'login', mark: true),
      ]);
      expect(highlight('nothing here', 'zzz'), [(text: 'nothing here', mark: false)]);
    });

    test('status line and grouping', () {
      final r = SearchResults.fromJson({
        'q': ' login ',
        'more': true,
        'chat': [],
        'terminals': [
          {'workerId': 'a', 'text': 'x', 'row': 1, 'rows': 2},
          {'workerId': 'gone', 'text': 'y', 'row': 1, 'rows': 2},
          {'workerId': 'a', 'text': 'z', 'row': 1, 'rows': 2},
        ],
      });
      final by = hitsByWorker(r, (id) => id != 'gone');
      expect(by.keys, ['a']);
      expect(by['a']!.length, 2);
      expect(searchStatus(r, 2), '2 lines, newest first (only the newest are shown; add words to narrow it down).');
      expect(searchStatus(r, 0), 'Nothing in the chat or any terminal matches “login”.');
    });
  });

  testWidgets('PromptField: Enter sends, Shift+Enter makes a new line', (tester) async {
    final c = TextEditingController();
    var sent = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptField(controller: c, onSend: () => sent++),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sent, 1);
  });

  testWidgets('StatusPill and ChildButton render and press', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        home: Scaffold(
          body: Column(
            children: [
              const StatusPill(WorkerStatus.needsInput),
              ChildButton(onPressed: () => pressed++, child: const Text('Nova')),
            ],
          ),
        ),
      ),
    );
    expect(find.text('needs input'), findsOneWidget);
    await tester.tap(find.text('Nova'));
    expect(pressed, 1);
    await tester.pump(const Duration(seconds: 2));
  });
}
