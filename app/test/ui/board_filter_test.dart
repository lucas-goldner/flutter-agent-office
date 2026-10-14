// Each board column's "Filter by title…" box (#165): it narrows the column, shows shown / total, ✕ clears
// it, and a refresh from GitHub keeps what's typed.

import 'package:agent_office/ui/boards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

Map<String, dynamic> issueJson(int n, String title) => {
  'number': n,
  'title': title,
  'state': 'OPEN',
  'url': 'https://github.com/acme/rocket/issues/$n',
  'author': 'a',
  'labels': [],
  'assignees': <String>[],
  'createdAt': '',
  'updatedAt': '2026-09-01',
  'body': '',
  'comments': 0,
};

void main() {
  testWidgets('typing narrows a column and a refresh keeps it', (tester) async {
    final office = Office()..welcome();
    void issues(List<Map<String, dynamic>> items) => office.store.apply(
      ServerMsg.parse({
        't': 'gh.issues',
        'state': {'items': items, 'fetchedAt': 1},
      }),
    );
    issues([issueJson(1, 'Fix the login page'), issueJson(2, 'Dark mode'), issueJson(3, 'Login with GitHub')]);
    await office.pump(tester, const SizedBox(), size: const Size(1600, 1000));
    openBoard(office.scope(), BoardKind.issues);
    await tester.pump();
    await tester.pump();
    expect(find.text('Fix the login page'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('search-open')).first, 'login');
    await tester.pump();
    expect(find.text('Dark mode'), findsNothing);
    expect(find.text('2 / 3'), findsOneWidget);
    issues([issueJson(1, 'Fix the login page'), issueJson(2, 'Dark mode'), issueJson(4, 'Login again')]);
    await tester.pump();
    expect(find.text('Login again'), findsOneWidget);
    expect(find.text('Dark mode'), findsNothing, reason: 'still filtered after the refresh');
    await tester.tap(find.text('✕').last);
    await tester.pump();
    expect(find.text('Dark mode'), findsOneWidget);
  });
}
