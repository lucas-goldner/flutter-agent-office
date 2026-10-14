import 'dart:ui' show VoidCallback;

import 'package:agent_office/world/drunk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prepare warms the filters once, before the first drunk frame', () {
    var renders = 0;
    final w = DrunkWarmup(render: () async => renders++);
    expect(w.prepared, isFalse);
    w.prepare();
    expect(renders, 1);
    w.prepare();
    expect(renders, 1);
  });

  test('queue does it later, once, however often it is asked', () {
    var renders = 0;
    final pending = <VoidCallback>[];
    final w = DrunkWarmup(render: () async => renders++, later: pending.add);
    w
      ..queue()
      ..queue();
    expect(pending, hasLength(1));
    expect(renders, 0);
    pending.single();
    expect(renders, 1);
    w.queue();
    expect(pending, hasLength(1), reason: 'already warm: nothing more to queue');
  });

  testWidgets('the real warm-up draws the filters off screen without failing', (tester) async {
    final w = DrunkWarmup();
    await tester.runAsync(() async => w.prepare());
    expect(w.prepared, isTrue);
  });
}
