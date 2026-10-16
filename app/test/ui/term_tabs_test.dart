// Terminal tabs (#212): a web page pinned open beside a worker's terminal, kept per worker until the page
// reloads.

import 'package:agent_office/net/api.dart';
import 'package:agent_office/ui/file_tab.dart';
import 'package:agent_office/ui/modal.dart';
import 'package:agent_office/ui/term_tabs.dart';
import 'package:agent_office/ui/term_tabs_logic.dart';
import 'package:agent_office/ui/terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void main() {
  test('only http(s) pages, never the office itself; a tab without a name is named for its site', () {
    const office = 'http://localhost:4600';
    expect(newWebTab('', 'not a url', officeOrigin: office).problem, 'That doesn’t look like a web address');
    expect(newWebTab('', 'ftp://x.org/a', officeOrigin: office).problem, contains('Only http:// and https://'));
    expect(newWebTab('', 'javascript:alert(1)', officeOrigin: office).problem, contains('Only http://'));
    expect(newWebTab('', 'http://localhost:4600/api', officeOrigin: office).problem, contains("office's own"));
    final t = newWebTab('', ' https://www.example.com/docs ', officeOrigin: office).tab!;
    expect((t.title, t.url), ('example.com', 'https://www.example.com/docs'));
    expect(newWebTab('  ChatGPT ', 'https://chatgpt.com/c/1', officeOrigin: office).tab!.title, 'ChatGPT');
    expect(newWebTab('a' * 60, 'https://x.org', officeOrigin: office).tab!.title, hasLength(40));
  });

  testWidgets('pin a page, switch back to the terminal, and it is still there next time', (tester) async {
    tabsByWorker.clear();
    debugWebPage = (t) => Text('page ${t.url}');
    addTearDown(() => debugWebPage = null);
    final office = Office()..welcome();
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': workerJson('w1')}));
    await office.pump(tester, const SizedBox());
    openTerminal(office.scope(), 'w1');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('term-tab-add')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('term-tab-name')), 'Docs');
    await tester.enterText(find.byKey(const ValueKey('term-tab-url')), 'https://example.com/docs');
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('🌐 Docs'), findsOneWidget);
    expect(find.text('page https://example.com/docs'), findsOneWidget);
    expect(find.byKey(const ValueKey('term-tab-out')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('term-tab-main')));
    await tester.pump();
    expect(find.text('page https://example.com/docs'), findsNothing, reason: 'kept, but not shown');
    expect(find.byKey(const ValueKey('term-tab-out')), findsNothing);

    // Closed and opened again: the tab is still there.
    ModalStack.instance.closeAll();
    await tester.pump();
    openTerminal(office.scope(), 'w1');
    await tester.pump();
    expect(find.text('🌐 Docs'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('term-tab-close-${tabsByWorker['w1']!.single.id}')));
    await tester.pump();
    expect(find.text('🌐 Docs'), findsNothing);
    expect(tabsByWorker['w1'], isEmpty);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets("+ File: the worker's .md and .txt files, newest first; one opens in a 📄 tab", (tester) async {
    tabsByWorker.clear();
    final asked = <String>[];
    workerFilesGet = (path) async {
      asked.add(path);
      if (path.startsWith('/api/worker/files')) {
        return ApiResult(200, {
          'files': [
            {'path': 'docs/old.md', 'size': 3, 'mtime': 1},
            {'path': 'notes/profile.md', 'title': 'Profile ideas', 'size': 3, 'mtime': 9},
            {'path': 'out.txt', 'size': 3, 'mtime': 5},
          ],
        });
      }
      final file = Uri.parse(path).queryParameters['path'];
      return ApiResult(200, {'path': file, 'text': file == 'out.txt' ? 'plain words' : '# Profile ideas\n\nTier 1'});
    };
    addTearDown(() => workerFilesGet = Api.getJson);
    final office = Office()..welcome();
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': workerJson('w1')}));
    await office.pump(tester, const SizedBox());
    openTerminal(office.scope(), 'w1');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('term-tab-file')));
    await tester.pumpAndSettle();
    expect(asked.single, contains('worker=w1'));
    final names = [
      for (final w in tester.widgetList<InkWell>(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('file-pick-') &&
              w is InkWell,
        ),
      ))
        (w.key as ValueKey<String>).value,
    ];
    expect(names, ['file-pick-notes/profile.md', 'file-pick-out.txt', 'file-pick-docs/old.md']);

    await tester.tap(find.byKey(const ValueKey('file-pick-notes/profile.md')));
    await tester.pumpAndSettle();
    expect(find.text('📄 profile.md'), findsOneWidget);
    expect(find.text('Profile ideas'), findsOneWidget, reason: 'the Markdown drawn');
    expect(find.byKey(const ValueKey('file-pick-filter')), findsNothing, reason: 'the picker closes');

    await tester.tap(find.byKey(const ValueKey('term-tab-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-pick-out.txt')));
    await tester.pumpAndSettle();
    expect(find.text('plain words'), findsOneWidget);
    expect(tabsByWorker['w1']!.map((t) => t.file), ['notes/profile.md', 'out.txt']);

    ModalStack.instance.closeAll();
    await tester.pump(const Duration(seconds: 5));
  });
}
