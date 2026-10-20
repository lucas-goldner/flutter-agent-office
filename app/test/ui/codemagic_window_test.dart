import 'package:agent_office/ui/codemagic_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/codemagic.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void main() {
  testWidgets('the build tower: start a workflow on a branch, and the builds with their light', (tester) async {
    final office = Office()..welcome();
    office.store.apply(
      const CodemagicMsg(
        CodemagicState(
          token: true,
          appId: 'app000001',
          appName: 'acme-app',
          workflows: [
            CodemagicWorkflow(id: 'ios-dev', name: 'iOS dev'),
            CodemagicWorkflow(id: 'android-dev', name: 'Android dev'),
          ],
          builds: [
            CodemagicBuild(
              id: 'b2',
              workflow: 'Android dev',
              branch: 'feature/qr',
              status: CodemagicStatus.failed,
              by: 'Bolt',
              link: 'https://codemagic.io/app/app000001/build/b2',
            ),
            CodemagicBuild(
              id: 'b1',
              workflow: 'iOS dev',
              branch: 'feature/qr',
              status: CodemagicStatus.building,
              index: 42,
            ),
          ],
        ),
      ),
    );
    await office.pump(tester, const SizedBox());
    openCodemagic(office.scope());
    await tester.pumpAndSettle();
    expect(find.text('🏗️ acme-app'), findsOneWidget);
    expect(find.text('🔴 failed  Android dev'), findsOneWidget);
    expect(find.text('🟡 building  iOS dev #42'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('codemagic-branch')), 'feature/qr');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codemagic-build-ios-dev')));
    await tester.pump();
    final sent = office.net.sent.whereType<CodemagicBuildCmd>().single;
    expect((sent.workflow, sent.branch), ('ios-dev', 'feature/qr'));
  });

  test('how long a build took, in words', () {
    expect(buildDuration(20000), '<1 min');
    expect(buildDuration(12 * 60000), '12 min');
    expect(buildDuration(65 * 60000), '1 h 5 min');
  });
}
