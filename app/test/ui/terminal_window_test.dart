// The terminal window's header: ⎋ Esc sends the program an Esc, Hide closes it, and Esc leaving while the
// program wanted one says how to send it one (#168, #322).

import 'package:agent_office/ui/modal.dart';
import 'package:agent_office/ui/terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import 'harness.dart';

void main() {
  Future<Office> open(WidgetTester tester, String screen) async {
    final office = Office()..welcome();
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': workerJson('w1', status: 'needs-input')}));
    await office.pump(tester, const SizedBox());
    openTerminal(office.scope(), 'w1');
    await tester.pump();
    office.net.incoming.add(
      ServerMsg.parse({'t': 'term.snapshot', 'workerId': 'w1', 'cols': 80, 'rows': 24, 'data': screen}),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return office;
  }

  testWidgets('⎋ Esc sends an Esc; Hide leaves the worker running', (tester) async {
    final office = await open(tester, 'hello\r\n');
    await tester.tap(find.byKey(const ValueKey('term-esc')));
    await tester.pump();
    expect(office.net.sent.whereType<TermInputCmd>().map((c) => c.data), contains('\x1b'));
    await tester.tap(find.byKey(const ValueKey('term-hide')));
    await tester.pump();
    expect(ModalStack.instance.open, isFalse);
    expect(office.net.sent.whereType<WorkerDetachCmd>(), isNotEmpty);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Esc leaves, with a tip when the screen wanted one', (tester) async {
    await open(tester, '  /skills\r\n  Esc to close\r\n');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(ModalStack.instance.open, isFalse);
    expect(Toasts.instance.items.value.single.text, startsWith('Esc left the terminal. To send Ww1 an Esc'));
    await tester.pump(const Duration(seconds: 4));
  });
}
