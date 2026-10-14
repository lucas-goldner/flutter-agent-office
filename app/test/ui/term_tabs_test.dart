// Terminal tabs (#212): a web page pinned open beside a worker's terminal, kept per worker until the page
// reloads.

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
}
