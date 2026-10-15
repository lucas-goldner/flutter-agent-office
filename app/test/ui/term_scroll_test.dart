// Scrolling a worker's terminal: back through its history with the wheel or a trackpad, and in a
// full-screen program (Claude Code's no-flicker mode: alternate screen + mouse reporting) as wheel
// events the program scrolls itself.

import 'package:agent_office/ui/terminal.dart';
import 'package:agent_office/ui/terminal_logic.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';
import 'package:xterm/xterm.dart' as x;

import 'harness.dart';

void main() {
  Future<Office> open(WidgetTester tester, String screen) async {
    final office = Office()..welcome();
    office.store.apply(ServerMsg.parse({'t': 'worker.update', 'worker': workerJson('w1', status: 'working')}));
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

  String lines(int n) => [for (var i = 0; i < n; i++) 'line $i\r\n'].join();
  Offset middle(WidgetTester tester) => tester.getCenter(find.byType(x.TerminalView));
  ScrollPosition pos(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(of: find.byType(x.TerminalView), matching: find.byType(Scrollable)).first)
      .position;

  testWidgets('the wheel scrolls back through the history', (tester) async {
    await open(tester, lines(300));
    final before = pos(tester).pixels;
    expect(before, greaterThan(0));
    await tester.sendEventToBinding(PointerScrollEvent(position: middle(tester), scrollDelta: const Offset(0, -400)));
    await tester.pump();
    expect(pos(tester).pixels, lessThan(before));
  });

  testWidgets('a trackpad scrolls back through the history', (tester) async {
    await open(tester, lines(300));
    final before = pos(tester).pixels;
    final pad = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pad.panZoomStart(middle(tester)));
    for (var i = 1; i <= 10; i++) {
      await tester.sendEventToBinding(pad.panZoomUpdate(middle(tester), pan: Offset(0, 40.0 * i)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(pad.panZoomEnd());
    await tester.pump();
    expect(pos(tester).pixels, lessThan(before));
  });

  testWidgets('a full-screen program with mouse reporting gets the wheel', (tester) async {
    final office = await open(tester, '\x1b[?1049h\x1b[?1000h\x1b[?1006h${lines(10)}');
    await tester.sendEventToBinding(PointerScrollEvent(position: middle(tester), scrollDelta: const Offset(0, -200)));
    await tester.pump();
    final sent = office.net.sent.whereType<TermInputCmd>().map((c) => c.data).join();
    final notch = RegExp(r'\x1b\[<(\d+);(\d+);(\d+)M').firstMatch(sent);
    expect(notch, isNotNull, reason: 'the program gets the wheel, not arrow keys');
    expect(notch!.group(1), '64', reason: 'wheel up is 64 (68 would be Shift + wheel)');
    expect(int.parse(notch.group(3)!), inInclusiveRange(1, 24), reason: 'on a row of the terminal, not of the window');
    expect(sent, isNot(contains('\x1b[A')));
    // Down, too.
    await tester.sendEventToBinding(PointerScrollEvent(position: middle(tester), scrollDelta: const Offset(0, 200)));
    await tester.pump();
    expect(office.net.sent.whereType<TermInputCmd>().map((c) => c.data).join(), contains('\x1b[<65;'));
  });

  test('wheel notches as a terminal reports them', () {
    expect(wheelReport(64, 0, 0, x.MouseReportMode.sgr), '\x1b[<64;1;1M');
    expect(wheelReport(65, 9, 4, x.MouseReportMode.urxvt), '\x1b[97;10;5M');
    expect(wheelReport(64, 0, 0, x.MouseReportMode.normal), '\x1b[M`!!');
  });
}
