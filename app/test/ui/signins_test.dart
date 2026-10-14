// 🔐 Your sign-ins (#146): who it greets, and what its buttons send.

import 'package:agent_office/ui/signins.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void signedInAs(Office office, {String? account = 'Ada'}) => office.store.apply(
  ServerMsg.parse({
    't': 'me',
    'me': {
      'admin': false,
      if (account != null) 'account': {'name': account, 'role': 'member'},
    },
  }),
);

void signIns(Office office, Map<String, dynamic> claude, [Map<String, dynamic>? github, bool own = false]) =>
    office.store.apply(
      ServerMsg.parse({
        't': 'signins',
        'state': {
          'claude': claude,
          'github': github ?? {'status': 'none', 'how': 'login'},
          'office': own,
        },
      }),
    );

void main() {
  testWidgets('greets an account with its Claude sign-in still to do, not the shared password', (tester) async {
    final office = Office()..welcome();
    await office.pump(tester, const SizedBox());
    signIns(office, {'status': 'none', 'how': 'login'});
    expect(needsSigningIn(office.scope()), isFalse, reason: 'on the shared password');
    signedInAs(office);
    expect(needsSigningIn(office.scope()), isTrue);
    signIns(office, {'status': 'none', 'how': 'office'});
    expect(needsSigningIn(office.scope()), isFalse, reason: "on the office's own");
    signIns(office, {'status': 'ok', 'how': 'login', 'who': 'ada@example.com'});
    expect(needsSigningIn(office.scope()), isFalse);
  });

  testWidgets('start a sign-in, paste the code, or a token', (tester) async {
    final office = Office()..welcome();
    signedInAs(office);
    signIns(office, {'status': 'none', 'how': 'login'}, null, true);
    await office.pump(tester, const SizedBox());
    openSignIns(office.scope(), 'Sign in to Claude to hire a worker');
    await tester.pump();
    expect(find.text('🔐 Your sign-ins'), findsOneWidget);
    expect(find.byKey(const ValueKey('signins-why')), findsOneWidget);
    expect(office.net.sent.whereType<SignInsGetCmd>(), hasLength(1));
    expect(find.text('Use the office’s own'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('signin-start-claude')));
    expect((office.net.sent.last as SignInsStartCmd).which, SignInKind.claude);

    // A token for GitHub, typed as dots.
    await tester.enterText(find.byType(TextField).last, ' ghp_abc ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    final token = office.net.sent.last as SignInsTokenCmd;
    expect((token.which, token.token), (SignInKind.github, 'ghp_abc'));
    expect(tester.widget<TextField>(find.byType(TextField).last).obscureText, isTrue);

    // The office hands back Claude's page: the code box shows.
    signIns(office, {
      'status': 'busy',
      'how': 'login',
      'pending': {'url': 'https://claude.ai/oauth/authorize?x=1'},
    });
    await tester.pump();
    expect(find.text('Open Claude’s sign-in page ↗'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('signin-code')), 'abc#def');
    await tester.tap(find.text('Send'));
    expect((office.net.sent.last as SignInsCodeCmd).code, 'abc#def');

    // Both done: what sent you here is too.
    signIns(
      office,
      {'status': 'ok', 'how': 'login', 'who': 'ada@example.com'},
      {'status': 'ok', 'how': 'login', 'who': '@ada'},
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('signins-why')), findsNothing);
    expect(find.text('✅ ada@example.com'), findsOneWidget);
    expect(find.text('Sign out'), findsNWidgets(2));
  });

  testWidgets('a second call says why in the window that is open', (tester) async {
    final office = Office()..welcome();
    signedInAs(office);
    await office.pump(tester, const SizedBox());
    openSignIns(office.scope());
    await tester.pump();
    expect(find.byKey(const ValueKey('signins-why')), findsNothing);
    openSignIns(office.scope(), 'Sign in to GitHub first');
    await tester.pump();
    expect(find.text('🔐 Your sign-ins'), findsOneWidget);
    expect(find.text('Sign in to GitHub first'), findsOneWidget);
  });
}
