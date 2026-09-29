// A snapshot gives the terminal window a fresh xterm controller. The view lets go of the old one
// while it rebuilds, so the old one may only be disposed after that frame (disposing it first threw
// "A TerminalController was used after being disposed" and broke the window in debug builds).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' as x;

void main() {
  testWidgets('swapping the controller, then disposing the old one after the frame', (tester) async {
    final term = x.Terminal();
    var ctl = x.TerminalController();
    late StateSetter set;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, s) {
            set = s;
            return x.TerminalView(term, controller: ctl);
          },
        ),
      ),
    );
    final old = ctl;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    set(() => ctl = x.TerminalController());
    await tester.pump();
    expect(tester.takeException(), isNull);
    term.write('still drawing\r\n');
    await tester.pump();
    expect(tester.takeException(), isNull);
    ctl.dispose();
  });
}
