import 'package:office_shared/protocol.dart';
import 'package:agent_office/ui/limits.dart';
import 'package:agent_office/ui/usage.dart' show MeterLevel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 9, 27, 14, 0).millisecondsSinceEpoch;

  test('reset countdowns', () {
    expect(fmtReset(now - 1000, now), 'now');
    expect(fmtReset(now + 12 * 60000 - 5000, now), 'in 12m');
    expect(fmtReset(now + 125 * 60000, now), 'in 2h 5m');
    expect(fmtReset(DateTime(2026, 9, 29, 5, 0).millisecondsSinceEpoch, now), 'Tue 5:00 AM');
  });

  test('levels, titles and plan names', () {
    expect(limitLevel(50), MeterLevel.ok);
    expect(limitLevel(75), MeterLevel.near);
    expect(limitLevel(90), MeterLevel.over);
    final w = PlanWindow(label: 'Week', pct: 41.6, resetsAt: DateTime(2026, 9, 29, 17, 30).millisecondsSinceEpoch);
    expect(limitTitle(w), 'Week (all models): 42% used\nStarts over Tuesday 5:30 PM');
    expect(planName('max'), 'Max');
    expect(planName(null), '');
    expect(clockTime(DateTime(2026, 1, 1, 0, 5)), '12:05 AM');
  });

  testWidgets('the panel lists each window and says when stale', (tester) async {
    final limits = PlanLimits(
      plan: 'pro',
      at: now - 20 * 60000,
      windows: [
        PlanWindow(label: '5h session', pct: 92, resetsAt: now + 30 * 60000),
        const PlanWindow(label: 'Week', pct: 10),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 250, child: LimitsView(limits, now: now)),
        ),
      ),
    );
    expect(find.text('CLAUDE LIMITS'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);
    expect(find.text('resets in 30m'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);
    expect(find.textContaining('As of '), findsOneWidget);
  });
}
