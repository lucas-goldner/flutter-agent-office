// A worker that needs you (tests/needsyou.test.ts): who just started asking, the banner, the reminders.

import 'package:agent_office/needs_you_logic.dart';
import 'package:agent_office/ui/needs_you.dart';
import 'package:agent_office/world/needs_you_beacon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

WorkerInfo worker(String id, String status, [Map<String, dynamic> more = const {}]) => WorkerInfo.fromJson({
  'id': id,
  'kind': 'agent',
  'deskId': 'desk-$id',
  'name': id,
  'color': '#fff',
  'status': status,
  'acked': false,
  'createdBy': 'test',
  'createdAt': 0,
  'cols': 80,
  'rows': 24,
  'viewers': <String>[],
  ...more,
});

Map<String, WorkerInfo> floor(List<WorkerInfo> ws) => {for (final w in ws) w.id: w};

List<String> ids(List<WorkerInfo> ws) => [for (final w in ws) w.id];

void main() {
  test('a worker that starts asking is new; one already asking when the page first saw it is not', () {
    final fresh = Fresh();
    // The page comes up with one asking already: the banner shows it, but nothing rings.
    expect(fresh.take(floor([worker('old', 'needs_input'), worker('busy', 'working')])), isEmpty);
    expect(ids(fresh.take(floor([worker('old', 'needs_input'), worker('busy', 'needs_input')]))), ['busy']);
    // Still asking: it rang already.
    expect(fresh.take(floor([worker('old', 'needs_input'), worker('busy', 'needs_input')])), isEmpty);
    // Answered, and asks something else.
    fresh.take(floor([worker('old', 'needs_input'), worker('busy', 'working')]));
    expect(ids(fresh.take(floor([worker('old', 'needs_input'), worker('busy', 'needs_input')]))), ['busy']);
    // Finishing isn't asking.
    expect(fresh.take(floor([worker('old', 'done'), worker('busy', 'needs_input')])), isEmpty);
  });

  test('workers on a floor you come back to are new to the page again, so arriving rings nothing', () {
    final fresh = Fresh();
    fresh.take(floor([worker('a', 'working')]));
    // Off to another floor, where b works, and a starts asking meanwhile.
    fresh.take(floor([worker('b', 'working')]));
    expect(fresh.take(floor([worker('a', 'needs_input')])), isEmpty);
  });

  test('the banner names whoever has waited longest, what it asks and for how long, and counts the rest', () {
    const now = 10 * 60000;
    final a = worker('Byte', 'needs_input', {
      'activity': 'Wants permission: Bash: npm test',
      'waitingSince': now - 4 * 60000,
    });
    final b = worker('Pixel', 'needs_input', {'activity': 'Which one?', 'waitingSince': now - 30000});
    final t = bannerText([a], now)!;
    expect(
      (t.id, t.title, t.detail, t.more),
      ('Byte', 'Byte needs you', 'Wants permission: Bash: npm test · 4 min', ''),
    );
    expect(t.key, 'Byte|Byte needs you|Wants permission: Bash: npm test · 4 min|');
    expect(bannerText([a, b], now)?.more, '+1 more');
    // In its first minute there's no time to give, and with nothing known of what it asks, just its name.
    expect(bannerText([b], now)?.detail, 'Which one?');
    expect(bannerText([worker('Nib', 'needs_input')], now)?.detail, '');
    // No activity: what its task says it's on.
    expect(
      bannerText([
        worker('Nib', 'needs_input', {
          'task': {'name': 'Docs', 'summary': 'Writing the docs'},
        }),
      ], now)?.detail,
      'Writing the docs',
    );
    // A long question is cut short, and its line breaks go.
    final long = bannerText([
      worker('Nib', 'needs_input', {'activity': 'Shall I\n${'x' * 200}'}),
    ], now)!;
    expect(long.detail.length, 90);
    expect(long.detail, matches(RegExp(r'^Shall I x+…$')));
    expect(bannerText([], now), isNull);
  });

  test('how long a worker has waited', () {
    expect(waited(null, 5000), '');
    expect(waited(0, 59000), '');
    expect(waited(0, 60000), '1 min');
    expect(waited(0, 59 * 60000 + 59000), '59 min');
    expect(waited(0, 65 * 60000), '1 h 05 min');
  });

  test('each wait of a worker has a key of its own, so a banner put away comes back when it asks again', () {
    expect(
      waitKey(worker('a', 'needs_input', {'waitingSince': 100})),
      isNot(waitKey(worker('a', 'needs_input', {'waitingSince': 200}))),
    );
    expect(
      waitKey(worker('a', 'needs_input', {'waitingSince': 100})),
      waitKey(worker('a', 'needs_input', {'waitingSince': 100, 'activity': 'other'})),
    );
  });

  test('the reminder rings every half minute while someone asks with nobody at its terminal', () {
    final r = Reminders();
    final asking = [worker('a', 'needs_input')];
    // The alarm rang as it started asking.
    r.rang(1000);
    expect(r.due(asking, 2000), isFalse);
    expect(r.due(asking, 1000 + remindEvery - 1), isFalse);
    expect(r.due(asking, 1000 + remindEvery.toDouble()), isTrue);
    // Once per wait, not on every look after it.
    expect(r.due(asking, 1000 + remindEvery + 1000), isFalse);
    expect(r.due(asking, 1000 + 2 * remindEvery.toDouble()), isTrue);
  });

  test('no reminder while someone has its terminal open, or with nobody asking; the wait starts over after', () {
    final r = Reminders()..rang(0);
    final watched = [
      worker('a', 'needs_input', {
        'viewers': ['you'],
      }),
    ];
    expect(r.due(watched, remindEvery * 3.0), isFalse);
    expect(r.due([], remindEvery * 3.0), isFalse);
    // They close it without answering: a whole wait from there before it rings.
    final asking = [worker('a', 'needs_input')];
    expect(r.due(asking, remindEvery * 3.0 + 1000), isFalse);
    expect(r.due(asking, remindEvery * 4.0), isFalse);
    expect(r.due(asking, remindEvery * 4.0 + 1000), isTrue);
    // One of two is being answered: the other still wants a reminder.
    expect(r.due([...watched, worker('b', 'needs_input')], remindEvery * 5.0 + 1000), isTrue);
  });

  test('arriving on a floor where someone is asking starts its wait over, however long ago the alarm last rang', () {
    final r = Reminders()
      ..rang(0)
      ..quiet();
    final asking = [worker('b', 'needs_input')];
    expect(r.due(asking, remindEvery * 10.0), isFalse);
    expect(r.due(asking, remindEvery * 11.0 - 1), isFalse);
    expect(r.due(asking, remindEvery * 11.0), isTrue);
  });

  test('a page that comes up with someone asking already waits a whole turn before the first reminder', () {
    final r = Reminders();
    final asking = [worker('a', 'needs_input')];
    expect(r.due(asking, 500000), isFalse);
    expect(r.due(asking, 500000.0 + remindEvery - 1), isFalse);
    expect(r.due(asking, 500000.0 + remindEvery), isTrue);
  });

  test('the beacon thins out as you walk up, and holds still for someone who asked for less motion', () {
    expect(beaconNearness(10), 0);
    expect(beaconNearness(2), 1);
    expect(beaconNearness(4.75), closeTo(0.5, 1e-9));
    final far = beaconLook(away: 12, t: 0, near: 0, calm: false);
    expect(far.pinScale, 2, reason: 'as big as it looked at 6 m');
    expect(far.beam, closeTo(0.64, 1e-9));
    expect(far.rings, hasLength(beaconRings.n));
    final close = beaconLook(away: 1, t: 0, near: 1, calm: false);
    expect(close.beam, 0, reason: 'no light between you and the laptop');
    expect(close.pinScale, 1);
    final calm = beaconLook(away: 30, t: 5, near: 0, calm: true);
    expect(calm.pinScale, pinSize.most);
    expect(calm.pinBob, 0);
    expect(calm.rings.whereType<Object>(), hasLength(1));
  });

  test('the edge flashes three times, or fades once with less motion', () {
    expect(needsYouFlashOpacity(0), 0);
    expect(needsYouFlashOpacity(0.12), closeTo(1, 1e-9));
    expect(needsYouFlashOpacity(0.29), closeTo(0.25, 1e-9));
    expect(needsYouFlashOpacity(1), 0);
    expect(needsYouFlashOpacity(0.25, calm: true), 0.75);
  });

  testWidgets('the banner: click to go to the worker, ✕ to put it away', (tester) async {
    final text = ValueNotifier<BannerText?>(null);
    String? went;
    var hidden = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: NeedsYouBanner(text: text, onGo: (id) => went = id, onHide: () => hidden++),
          ),
        ),
      ),
    );
    expect(find.text('Byte needs you'), findsNothing);
    text.value = const BannerText(id: 'w1', title: 'Byte needs you', detail: 'Which one? · 4 min', more: '+1 more');
    await tester.pump();
    expect(find.text('Byte needs you'), findsOneWidget);
    expect(find.text('+1 more'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('needs-you-go')));
    await tester.tap(find.byKey(const ValueKey('needs-you-hide')));
    expect((went, hidden), ('w1', 1));
    text.value = null;
    await tester.pump();
    expect(find.text('Byte needs you'), findsNothing);
  });
}
