// ⚙️ Settings → Building: the dog's breed and coat (#220), and which clock the sky keeps (#219).

import 'package:agent_office/notify.dart';
import 'package:agent_office/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

import '../notify_test.dart' show FakeApi;
import 'harness.dart';

void main() {
  Future<Office> openIt(WidgetTester tester) async {
    final office = Office()..welcome();
    office.store
      ..apply(
        ServerMsg.parse({
          't': 'dog',
          'dog': {
            'name': 'Biscuit',
            'coat': 1,
            'breed': 'corgi',
            'path': [
              [0, 0],
            ],
            'speed': 0,
            'elapsed': 0,
            'act': 'sit',
          },
        }),
      )
      ..apply(
        ServerMsg.parse({
          't': 'sky',
          'state': {'lat': 52.5, 'lon': 13.4, 'utcOffset': 60, 'weather': 'clear', 'intensity': 0},
        }),
      );
    await office.pump(tester, const SizedBox(), size: const Size(1400, 3000));
    lastSettingsPane = SettingsPane.building;
    openSettings(
      office.scope(),
      settings: office.settings,
      onChange: (_) {},
      onCharacter: () {},
      previewSound: () {},
      notifier: DesktopNotifier(enabled: () => true, openWorker: (_) {}, api: FakeApi()),
      onSignOut: () {},
    );
    await tester.pump();
    await tester.pump();
    return office;
  }

  testWidgets('the dog: a breed and a coat for everyone on the floor', (tester) async {
    final office = await openIt(tester);
    expect(find.text('Office dog'), findsOneWidget);
    expect(find.textContaining('Its name, breed and coat are for everyone on this floor.'), findsOneWidget);
    await tester.ensureVisible(find.text('🧸 Pomeranian'));
    await tester.tap(find.text('🧸 Pomeranian'));
    await tester.tap(find.text('🦊 Corgi'));
    await tester.tap(find.byKey(const ValueKey('coat-6')));
    await tester.tap(find.byKey(const ValueKey('coat-1')));
    await tester.pump();
    expect(office.net.sent.whereType<DogBreedCmd>().map((c) => c.breed), ['pomeranian'], reason: 'not the one it is');
    expect(office.net.sent.whereType<DogCoatCmd>().map((c) => c.coat), [6]);
  });

  testWidgets('the sky: the real clock or a day every hour, for everyone', (tester) async {
    final office = await openIt(tester);
    expect(find.text('Outside'), findsOneWidget);
    expect(find.textContaining('a whole day and night every hour'), findsOneWidget);
    expect(find.textContaining(' outside'), findsWidgets);
    await tester.ensureVisible(find.text('🕰️ Real time (24 h)'));
    await tester.tap(find.text('🕰️ Real time (24 h)'));
    await tester.pump();
    expect(office.net.sent.whereType<SkyClockCmd>().single.real, isTrue);
    office.store.apply(
      ServerMsg.parse({
        't': 'sky',
        'state': {'lat': 52.5, 'lon': 13.4, 'utcOffset': 60, 'weather': 'clear', 'intensity': 0, 'realTime': true},
      }),
    );
    await tester.pump();
    expect(find.textContaining('the real time of day'), findsOneWidget);
  });
}
