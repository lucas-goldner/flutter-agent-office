// A press on a window must never close it, however long it lasts (a slow click, a slider drag);
// a press on the backdrop around it still does.

import 'package:agent_office/ui/modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a long press inside the window keeps it; a tap outside closes it', (tester) async {
    final overlay = GlobalKey<OverlayState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(key: overlay, initialEntries: [OverlayEntry(builder: (_) => const SizedBox.expand())]),
      ),
    );
    ModalStack.instance.attach(overlay.currentState!);
    var closed = false;
    ModalStack.instance.show(
      (m) => Material(
        child: SizedBox(width: 200, height: 120, child: Center(child: TextButton(onPressed: () {}, child: const Text('inside')))),
      ),
      onClose: () => closed = true,
    );
    await tester.pumpAndSettle();
    final g = await tester.startGesture(tester.getCenter(find.text('inside')));
    await tester.pump(const Duration(milliseconds: 400));
    await g.up();
    await tester.pumpAndSettle();
    expect(closed, isFalse, reason: 'a slow click on the window closed it');
    expect(ModalStack.instance.open, isTrue);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(ModalStack.instance.open, isFalse);
  });
}
